import CoreGraphics
import Foundation
import SilveranAppleWidgets
import SilveranKit
import Testing

/// Regression coverage for the sideloaded Continue widget's two historical
/// failure modes: a hard-coded App Group id (blank tile on AltStore-resigned
/// builds) and a payload without transport state.
@Suite("Continue widget App Group resolution")
struct ContinueWidgetAppGroupTests {
    @Test func altStoreGroupsWinOverConfiguredValue() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: ["group.com.punkrally.reader.ABCDE12345"],
            configured: "group.com.punkrally.reader",
            fallback: "group.com.punkrally.reader",
        )
        // AltStore appends the team id; the Info.plist literal must not win.
        #expect(candidates.first == "group.com.punkrally.reader.ABCDE12345")
        #expect(candidates.count == 2)
    }

    @Test func backfillsConfiguredAndFallbackInOrder() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: nil,
            configured: "group.custom.reader",
            fallback: "group.com.punkrally.reader",
        )
        #expect(candidates == ["group.custom.reader", "group.com.punkrally.reader"])
    }

    @Test func rejectsEmptyAndUnexpandedIdentifiers() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: ["", "   ", "$(APP_GROUP_ID)"],
            configured: "$(SILVERAN_WIDGET_APP_GROUP)",
            fallback: "group.com.punkrally.reader",
        )
        #expect(candidates == ["group.com.punkrally.reader"])
    }

    @Test func deduplicatesRepeatedGroups() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: ["group.com.punkrally.reader"],
            configured: "group.com.punkrally.reader",
            fallback: "group.com.punkrally.reader",
        )
        #expect(candidates == ["group.com.punkrally.reader"])
    }

    @Test func altStoreInfoKeyMatchesAltStoreResignContract() {
        // AltStore's ResignAppOperation writes the granted groups here.
        #expect(SilveranWidgetConstants.altStoreAppGroupsInfoKey == "ALTAppGroups")
        #expect(SilveranWidgetConstants.appGroupInfoKey == "SILVERAN_WIDGET_APP_GROUP")
    }

    @Test func widgetStateLivesInHiddenBackupExcludedDirectory() {
        let container = URL(fileURLWithPath: "/tmp/AppGroup", isDirectory: true)
        let state = SilveranWidgetSnapshotStore.transientStateDirectory(in: container)
        #expect(state.lastPathComponent == ".InkAmpWidgetState")
        #expect(state.lastPathComponent.hasPrefix("."))
        #expect(state.deletingLastPathComponent().standardizedFileURL == container.standardizedFileURL)
    }

    @Test func fourContinueKindsAreUniqueAndNotLegacy() {
        let kinds = SilveranWidgetConstants.continueWidgetKinds
        #expect(kinds.count == 4)
        #expect(Set(kinds).count == 4)
        #expect(kinds == [
            "inkamp.continue.light.medium.v2",
            "inkamp.continue.light.large.v1",
            "inkamp.continue.dark.medium.v2",
            "inkamp.continue.dark.large.v1",
        ])
        // reloadTimelines() iterates continueWidgetKinds — publish must hit all four.
        #expect(
            ContinueWidgetSnapshotStore.timelineKindsToReload
                == SilveranWidgetConstants.continueWidgetKinds
        )
        for kind in kinds {
            #expect(kind != SilveranWidgetConstants.readingWidgetKind)
            for legacy in SilveranWidgetConstants.legacySideloadContinueWidgetKinds {
                #expect(legacy != kind)
            }
        }
        #expect(
            SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                "inkamp.continue.upnext.v1"
            )
        )
        #expect(
            SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                "InkAmpContinueWidget"
            )
        )
        #expect(
            SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                "inkamp.continue.light.medium.v1"
            )
        )
        #expect(
            SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                "inkamp.continue.dark.medium.v1"
            )
        )
    }
}

@Suite("Portable credential backup payload")
struct PortableCredentialBackupTests {
    @Test func credentialAllowlistRoundTripsEverySecretKind() throws {
        let original = AuthenticationActor.PortableBackup(
            storyteller: [
                .init(
                    sourceID: "source-a",
                    url: "https://story.example",
                    lanURL: "http://story.local",
                    username: "reader",
                    password: "story-secret"
                )
            ],
            legacyStoryteller: .init(
                url: "https://legacy.example",
                username: "legacy",
                password: "legacy-secret"
            ),
            hardcoverToken: "hardcover",
            lazyLibrarianAPIKey: "lazy",
            prowlarrAPIKey: "prowlarr",
            jackettAPIKey: "jackett",
            delugePassword: "deluge",
            qbittorrentPassword: "qbit",
            synologyPassword: "synology",
            torboxAPIKey: "torbox",
            torboxarrPassword: "torboxarr"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            AuthenticationActor.PortableBackup.self,
            from: encoded
        )
        #expect(decoded == original)
    }
}

@Suite("Continue widget snapshot payload")
struct ContinueWidgetSnapshotTests {
    @Test func transportControlsNeedALiveSession() {
        var snapshot = ContinueWidgetSnapshot(title: "Piranesi")
        #expect(snapshot.hasItem)
        // No live session → the tile must offer a deep link, not a dead button.
        #expect(!snapshot.supportsTransportControls)
        #expect(!snapshot.isLive)

        snapshot.hasLiveSession = true
        #expect(snapshot.supportsTransportControls)
    }

    @Test func emptyTitlesDoNotCountAsItems() {
        let snapshot = ContinueWidgetSnapshot(title: "   ")
        #expect(!snapshot.hasItem)
        #expect(!snapshot.supportsTransportControls)
    }

    @Test func progressCaptionCombinesPercentAndRemaining() {
        let snapshot = ContinueWidgetSnapshot(
            title: "Piranesi",
            progress: 0.5,
            durationSeconds: 3600,
        )
        #expect(snapshot.percentComplete == 50)
        #expect(snapshot.remainingText == "30m left")
        #expect(snapshot.progressCaption == "50% · 30m left")
    }

    @Test func clampingAndDurationFormatting() {
        #expect(ContinueWidgetSnapshot(progress: 1.4).clampedProgress == 1)
        #expect(ContinueWidgetSnapshot(progress: -0.2).clampedProgress == 0)
        #expect(ContinueWidgetSnapshot.durationText(90) == "1m")
        #expect(ContinueWidgetSnapshot.durationText(3600) == "1h")
        #expect(ContinueWidgetSnapshot.durationText(3900) == "1h 5m")
    }

    @Test func decodesSnapshotsWrittenBeforeTransportFieldsExisted() throws {
        // v3/v4 payloads on disk have no progress / live-session fields.
        let legacyJSON = """
            {
              "generatedAt": "2026-09-16T12:00:00Z",
              "isPlaying": true,
              "kind": "audiobook",
              "title": "Piranesi",
              "subtitle": "Susanna Clarke"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            ContinueWidgetSnapshot.self,
            from: Data(legacyJSON.utf8),
        )
        #expect(snapshot.hasItem)
        #expect(snapshot.isPlaying)
        #expect(snapshot.hasLiveSession == nil)
        // A legacy payload must not render dead transport buttons.
        #expect(!snapshot.supportsTransportControls)
        #expect(snapshot.upNext == nil)
        #expect(snapshot.upNextItems.isEmpty)
    }

    @Test func upNextPaintsAtMostThreeInSnapshot() {
        let items = (0..<5).map { index in
            ContinueWidgetQueueItem(
                id: "pod:\(index)",
                title: "Episode \(index)",
                kind: .podcast,
                deepLink: InkAmpContinueLink.queueItemURL(id: "pod:\(index)").absoluteString,
            )
        }
        let snapshot = ContinueWidgetSnapshot(title: "Piranesi", upNext: items)
        #expect(snapshot.upNextItems.count == ContinueWidgetSnapshot.upNextLimit)
        #expect(snapshot.upNextItems.map(\.id) == ["pod:0", "pod:1", "pod:2"])
        #expect(snapshot.upNextItems.allSatisfy { !$0.deepLink.isEmpty })
    }

    @Test func snapshotWithCurrentAndThreeUpNextDecodes() throws {
        let snapshot = ContinueWidgetSnapshot(
            title: "The Quiet Path",
            subtitle: "Ella Monroe",
            kind: .audiobook,
            deepLink: InkAmpContinueLink.continueURL.absoluteString,
            progress: 0.56,
            elapsedSeconds: 17_640,
            durationSeconds: 31_680,
            upNext: [
                ContinueWidgetQueueItem(
                    id: "book:preview/good-energy",
                    title: "Good Energy",
                    subtitle: "Casey Lin",
                    kind: .ebook,
                    deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/good-energy")
                        .absoluteString,
                ),
                ContinueWidgetQueueItem(
                    id: "book:preview/next-chapter",
                    title: "The Next Chapter",
                    subtitle: "Jordan Lee",
                    kind: .audiobook,
                    deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/next-chapter")
                        .absoluteString,
                ),
                ContinueWidgetQueueItem(
                    id: "book:preview/make-it-happen",
                    title: "Make It Happen",
                    subtitle: "Avery Chen",
                    kind: .ebook,
                    deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/make-it-happen")
                        .absoluteString,
                ),
            ],
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ContinueWidgetSnapshot.self, from: data)
        #expect(decoded.title == "The Quiet Path")
        #expect(decoded.subtitle == "Ella Monroe")
        #expect(decoded.progressCaption == "56% · 3h 54m left")
        #expect(decoded.upNextItems.count == 3)
        #expect(decoded.upNextItems.map(\.title) == [
            "Good Energy",
            "The Next Chapter",
            "Make It Happen",
        ])
    }

    @Test func mediumRendersAtMostTwoUpNextRows() {
        let items = (0..<5).map { index in
            ContinueWidgetQueueItem(
                id: "pod:\(index)",
                title: "Episode \(index)",
                kind: .podcast,
                deepLink: InkAmpContinueLink.queueItemURL(id: "pod:\(index)").absoluteString,
            )
        }
        let snapshot = ContinueWidgetSnapshot(title: "Now", upNext: items)
        let painted = InkAmpContinueWidgetActions.upNextItems(for: snapshot, layout: .medium)
        #expect(InkAmpContinueWidgetLayout.medium.upNextLimit == 2)
        #expect(painted.count == 2)
        #expect(painted.map(\.id) == ["pod:0", "pod:1"])
    }

    @Test func largeRendersAtMostThreeUpNextRows() {
        let items = (0..<5).map { index in
            ContinueWidgetQueueItem(
                id: "pod:\(index)",
                title: "Episode \(index)",
                kind: .podcast,
                deepLink: InkAmpContinueLink.queueItemURL(id: "pod:\(index)").absoluteString,
            )
        }
        let snapshot = ContinueWidgetSnapshot(title: "Now", upNext: items)
        let painted = InkAmpContinueWidgetActions.upNextItems(for: snapshot, layout: .large)
        #expect(InkAmpContinueWidgetLayout.large.upNextLimit == 3)
        #expect(painted.count == 3)
        #expect(painted.map(\.id) == ["pod:0", "pod:1", "pod:2"])
    }

    @Test func continueUsesCurrentDeepLink() {
        let custom = "punkrally://continue?item=book:storyteller/abc"
        let snapshot = ContinueWidgetSnapshot(title: "Now", deepLink: custom)
        #expect(
            InkAmpContinueWidgetActions.continueURL(for: snapshot).absoluteString == custom
        )
        let empty = ContinueWidgetSnapshot.empty
        #expect(
            InkAmpContinueWidgetActions.continueURL(for: empty)
                == InkAmpContinueLink.continueURL
        )
    }

    @Test func upNextUsesRowDeepLinks() {
        let item = ContinueWidgetQueueItem(
            id: "pod:ep-9",
            title: "Cold Open",
            kind: .podcast,
            deepLink: "punkrally://continue?item=pod:ep-9",
        )
        #expect(
            InkAmpContinueWidgetActions.upNextURL(for: item).absoluteString
                == "punkrally://continue?item=pod:ep-9"
        )
    }

    @Test func emptySnapshotProducesEmptyState() {
        let empty = ContinueWidgetSnapshot.empty
        #expect(InkAmpContinueWidgetActions.showsEmptyState(empty))
        #expect(!empty.hasItem)
        let withItem = ContinueWidgetSnapshot(title: "Now")
        #expect(!InkAmpContinueWidgetActions.showsEmptyState(withItem))
    }

    @Test func activePlaybackDarkAppearanceKeepsTheItem() {
        let loaded = ContinueWidgetSnapshot(
            title: "Piranesi",
            subtitle: "Susanna Clarke",
            isPlaying: true,
            kind: .audiobook,
            upNext: [
                ContinueWidgetQueueItem(
                    id: "pod:ep-1",
                    title: "Cold Open",
                    kind: .podcast,
                    deepLink: InkAmpContinueLink.queueItemURL(id: "pod:ep-1").absoluteString,
                )
            ],
        )
        let resolved = InkAmpContinueTimelineResolver.resolve(
            loaded: loaded,
            phase: .timeline,
            theme: .dark,
        )
        #expect(resolved.snapshot.title == "Piranesi")
        #expect(resolved.snapshot.upNext?.count == 1)
        #expect(!resolved.showsEmptyState)
        #expect(!resolved.isPlaceholder)
        #expect(resolved.phase == .timeline)
    }

    @Test func activePlaybackLightAppearanceKeepsTheItem() {
        let loaded = ContinueWidgetSnapshot(title: "Piranesi", isPlaying: true, kind: .audiobook)
        let resolved = InkAmpContinueTimelineResolver.resolve(
            loaded: loaded,
            phase: .timeline,
            theme: .light,
        )
        #expect(resolved.snapshot == loaded)
        #expect(resolved.snapshot.title == "Piranesi")
        #expect(!resolved.showsEmptyState)
        #expect(!resolved.isPlaceholder)
    }

    @Test func noPlaybackShowsNothingInProgressModel() {
        for theme in InkAmpWidgetTheme.allCases {
            let resolved = InkAmpContinueTimelineResolver.resolve(
                loaded: .empty,
                phase: .timeline,
                theme: theme,
            )
            #expect(resolved.showsEmptyState)
            #expect(resolved.snapshot.title == nil)
            #expect(!resolved.isPlaceholder)
            #expect(resolved.phase == .timeline)
        }
    }

    @Test func liveTimelineIsNotThePlaceholderSample() {
        let sample = ContinueWidgetSnapshot(title: "The Quiet Path")
        let placeholder = InkAmpContinueTimelineResolver.placeholder(sample: sample)
        #expect(placeholder.isPlaceholder)
        #expect(placeholder.phase == .placeholder)
        // An empty gallery sample still must not take the live empty-state branch.
        let emptySample = InkAmpContinueTimelineResolver.placeholder(sample: .empty)
        #expect(emptySample.isPlaceholder)
        #expect(!emptySample.showsEmptyState)

        let live = InkAmpContinueTimelineResolver.resolve(
            loaded: sample,
            phase: .snapshot,
            theme: .light,
        )
        #expect(!live.isPlaceholder)
        #expect(live.phase == .snapshot)
        #expect(live.snapshot == sample)
    }

    @Test func themeSelectionDoesNotChangeThePlaybackModel() {
        let loaded = ContinueWidgetSnapshot(
            title: "Piranesi",
            isPlaying: false,
            kind: .ebook,
            progress: 0.4,
            upNext: [
                ContinueWidgetQueueItem(
                    id: "book:storyteller/abc",
                    title: "Next",
                    kind: .ebook,
                    deepLink: InkAmpContinueLink.queueItemURL(id: "book:storyteller/abc")
                        .absoluteString,
                )
            ],
        )
        let paints = InkAmpWidgetTheme.allCases.map { theme in
            InkAmpContinueTimelineResolver.resolve(
                loaded: loaded,
                phase: .timeline,
                theme: theme,
            )
        }
        #expect(paints.count == 2)
        #expect(paints.allSatisfy { $0.snapshot == loaded && !$0.isPlaceholder && !$0.showsEmptyState })
        #expect(paints[0] == paints[1])

        let snapshotPhase = InkAmpContinueTimelineResolver.resolve(
            loaded: loaded,
            phase: .snapshot,
            theme: .dark,
        )
        let timelinePhase = InkAmpContinueTimelineResolver.resolve(
            loaded: loaded,
            phase: .timeline,
            theme: .light,
        )
        #expect(snapshotPhase.snapshot == timelinePhase.snapshot)
        #expect(snapshotPhase.phase == .snapshot)
        #expect(timelinePhase.phase == .timeline)
    }

    @Test func timelineLogNamesKindFamilyThemePhaseTitleAndQueue() {
        let loaded = ContinueWidgetSnapshot(
            title: "Piranesi",
            upNext: [
                ContinueWidgetQueueItem(
                    id: "pod:ep-1",
                    title: "Cold Open",
                    kind: .podcast,
                    deepLink: "punkrally://continue?item=pod:ep-1",
                )
            ],
        )
        let line = InkAmpContinueTimelineResolver.logLine(
            kind: "inkamp.continue.light.medium.v2",
            family: "systemMedium",
            theme: .light,
            phase: .timeline,
            isPreview: false,
            snapshot: loaded,
        )
        #expect(line.contains("kind=inkamp.continue.light.medium.v2"))
        #expect(line.contains("family=systemMedium"))
        #expect(line.contains("theme=light"))
        #expect(line.contains("phase=timeline"))
        #expect(line.contains("preview=false"))
        #expect(line.contains("title=Piranesi"))
        #expect(line.contains("queue=1"))

        let empty = InkAmpContinueTimelineResolver.logLine(
            kind: "inkamp.continue.dark.large.v1",
            family: "systemLarge",
            theme: .dark,
            phase: .snapshot,
            isPreview: true,
            snapshot: .empty,
        )
        #expect(empty.contains("kind=inkamp.continue.dark.large.v1"))
        #expect(empty.contains("theme=dark"))
        #expect(empty.contains("phase=snapshot"))
        #expect(empty.contains("title=nil"))
        #expect(empty.contains("queue=0"))
        #expect(empty.contains("preview=true"))
    }

    @Test func homeScreenWidgetsDoNotUsePlaybackTransportIntents() {
        #expect(!InkAmpContinueWidgetActions.usesPlaybackTransportIntents)
        #expect(
            InkAmpContinueWidgetActions.browseQueueURL() == InkAmpContinueLink.homeURL
        )
    }

    @Test func lightAndDarkPaletteConstantsMatchApprovedHex() {
        #expect(InkAmpBrandPalette.aqua == "#95D9C0")
        #expect(InkAmpBrandPalette.blanc == "#FFFFFF")
        #expect(InkAmpBrandPalette.carmin == "#D41F26")
        #expect(InkAmpBrandPalette.tangerine == "#F58F20")
        #expect(InkAmpBrandPalette.leafGreen == "#467434")
        #expect(InkAmpBrandPalette.seaGrey == "#363636")
        #expect(InkAmpContinueWidgetPalette.Light.aqua == InkAmpBrandPalette.aqua)
        #expect(InkAmpContinueWidgetPalette.Light.blanc == InkAmpBrandPalette.blanc)
        #expect(InkAmpContinueWidgetPalette.Light.carmin == InkAmpBrandPalette.carmin)
        #expect(InkAmpContinueWidgetPalette.Dark.tangerine == InkAmpBrandPalette.tangerine)
        #expect(InkAmpContinueWidgetPalette.Dark.leafGreen == InkAmpBrandPalette.leafGreen)
        #expect(InkAmpContinueWidgetPalette.Dark.seaGrey == InkAmpBrandPalette.seaGrey)
    }

    @Test func upNextRoundTripsThroughJSON() throws {
        let snapshot = ContinueWidgetSnapshot(
            title: "Piranesi",
            kind: .audiobook,
            deepLink: InkAmpContinueLink.continueURL.absoluteString,
            upNext: [
                ContinueWidgetQueueItem(
                    id: "pod:ep-1",
                    title: "Cold Open",
                    kind: .podcast,
                    deepLink: InkAmpContinueLink.queueItemURL(id: "pod:ep-1").absoluteString,
                    progress: 0.2,
                )
            ],
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ContinueWidgetSnapshot.self, from: data)
        #expect(decoded.upNextItems.count == 1)
        #expect(decoded.upNextItems[0].id == "pod:ep-1")
        #expect(decoded.upNextItems[0].title == "Cold Open")
        #expect(decoded.upNextItems[0].kind == .podcast)
        #expect(decoded.deepLink == InkAmpContinueLink.continueURL.absoluteString)
    }

    @Test func mediumWidthFractionsSumAndFavorCurrent() {
        let current = InkAmpContinueWidgetMetrics.mediumCurrentFraction
        let queue = InkAmpContinueWidgetMetrics.mediumQueueFraction
        #expect(abs(current + queue - 1) < 0.0001)
        #expect(current > queue)
        #expect(current == 0.58)
        #expect(queue == 0.42)

        let usable: CGFloat = 320
        let currentWidth = InkAmpContinueWidgetMetrics.mediumCurrentWidth(usableWidth: usable)
        let queueWidth = InkAmpContinueWidgetMetrics.mediumQueueWidth(usableWidth: usable)
        #expect(abs(currentWidth + queueWidth - usable) < 0.0001)
        #expect(currentWidth > queueWidth)
        #expect(queueWidth != InkAmpContinueWidgetMetrics.deprecatedMediumFixedQueueWidth)
        #expect(
            InkAmpContinueWidgetMetrics.mediumQueueWidth(usableWidth: 300)
                != InkAmpContinueWidgetMetrics.deprecatedMediumFixedQueueWidth
        )
    }

    @Test func mediumCoverIsMateriallySmallerThanLargeCover() {
        #expect(InkAmpContinueWidgetMetrics.mediumCoverSize >= 52)
        #expect(InkAmpContinueWidgetMetrics.mediumCoverSize <= 56)
        #expect(InkAmpContinueWidgetMetrics.mediumQueueCoverSize >= 22)
        #expect(InkAmpContinueWidgetMetrics.mediumQueueCoverSize <= 24)
        #expect(InkAmpContinueWidgetMetrics.largeCoverSize == 92)
        #expect(
            InkAmpContinueWidgetMetrics.mediumCoverSize
                <= InkAmpContinueWidgetMetrics.largeCoverSize - 30
        )
    }

    @Test func mediumAndLargeUpNextLimitsRemainDistinct() {
        #expect(InkAmpContinueWidgetLayout.medium.upNextLimit == 2)
        #expect(InkAmpContinueWidgetLayout.large.upNextLimit == 3)
    }

    @Test func mediumVerticalBudgetFitsSystemMediumPreviewCanvas() {
        #expect(InkAmpContinueWidgetMetrics.mediumCaptionFontSize >= 8)
        #expect(InkAmpContinueWidgetMetrics.mediumCaptionFontSize <= 9)
        #expect(InkAmpContinueWidgetMetrics.mediumProgressHeight < 5)
        #expect(InkAmpContinueWidgetMetrics.mediumNowColumnSpacing <= 5)

        let withCaption = InkAmpContinueWidgetMetrics.mediumContentMinimumHeight(
            includeCaption: true
        )
        let withoutCaption = InkAmpContinueWidgetMetrics.mediumContentMinimumHeight(
            includeCaption: false
        )
        #expect(withCaption > withoutCaption)
        #expect(withCaption <= InkAmpContinueWidgetMetrics.mediumPreviewHeight)
        #expect(
            InkAmpContinueWidgetMetrics.mediumNowColumnMinimumHeight(includeCaption: true)
                < InkAmpContinueWidgetMetrics.mediumCoverSize * 2
        )
    }
}

@Suite("Continue widget current snapshot selection")
struct ContinueWidgetCurrentSnapshotTests {
    private var troop: ContinueWidgetSnapshot {
        ContinueWidgetSnapshot(
            title: "The Troop",
            isPlaying: true,
            kind: .audiobook,
            deepLink: InkAmpContinueLink.continueURL.absoluteString,
            progress: 0.04,
            itemID: "book:storyteller/troop",
        )
    }

    private var vergecast: ContinueWidgetSnapshot {
        ContinueWidgetSnapshot(
            title: "Dots get up...",
            isPlaying: true,
            kind: .podcast,
            deepLink: InkAmpContinueLink.continueURL.absoluteString,
            progress: 0.18,
            itemID: "pod:vergecast-123",
        )
    }

    @Test func compactAndLargeFamiliesSelectTheSameCurrentSnapshot() {
        let selected = ContinueWidgetTimelineFamily.allCases.map { family in
            ContinueWidgetCurrentSnapshot.snapshot(
                for: family,
                shared: vergecast,
                localFallback: troop,
                sharedContainerReachable: true,
            )
        }
        #expect(Set(selected.map(\.mediaIdentity)).count == 1)
        #expect(selected.allSatisfy { $0.title == "Dots get up..." })
        #expect(selected.allSatisfy { $0.kind == .podcast })
        #expect(selected.allSatisfy { $0.percentComplete == 18 })
    }

    @Test func audiobookToPodcastResolvesThePodcastForEveryFamily() {
        for family in ContinueWidgetTimelineFamily.allCases {
            let resolved = ContinueWidgetCurrentSnapshot.snapshot(
                for: family,
                shared: vergecast,
                localFallback: troop,
                sharedContainerReachable: true,
            )
            #expect(resolved.mediaIdentity == vergecast.mediaIdentity)
            #expect(resolved.title == "Dots get up...")
        }
        #expect(
            ContinueWidgetReloadPolicy.shouldReload(
                previous: troop,
                next: vergecast,
                lastReload: Date(),
                now: Date(),
            )
        )
    }

    @Test func compactDoesNotPreferOlderPersistedAudiobookOverSharedSnapshot() {
        let compact = ContinueWidgetCurrentSnapshot.snapshot(
            for: .systemSmall,
            shared: vergecast,
            localFallback: troop,
            sharedContainerReachable: true,
        )
        let large = ContinueWidgetCurrentSnapshot.snapshot(
            for: .systemLarge,
            shared: vergecast,
            localFallback: troop,
            sharedContainerReachable: true,
        )
        #expect(compact.mediaIdentity == large.mediaIdentity)
        #expect(compact.title != "The Troop")
        #expect(compact.title == vergecast.title)
        let reachableEmpty = ContinueWidgetCurrentSnapshot.select(
            shared: .empty,
            localFallback: troop,
            sharedContainerReachable: true,
        )
        #expect(!reachableEmpty.hasItem)
    }

    @Test func refreshRequestIncludesCompactWidgetKinds() {
        let kinds = ContinueWidgetSnapshotStore.timelineKindsToReload
        #expect(kinds.contains("inkamp.continue.light.medium.v2"))
        #expect(kinds.contains("inkamp.continue.dark.medium.v2"))
        #expect(kinds.contains("inkamp.continue.light.large.v1"))
        #expect(kinds.contains("inkamp.continue.dark.large.v1"))
        #expect(
            ContinueWidgetSnapshotStore.compactTimelineKinds.sorted()
                == [
                    "inkamp.continue.dark.medium.v2",
                    "inkamp.continue.light.medium.v2",
                ]
        )
        #expect(Set(ContinueWidgetSnapshotStore.compactTimelineKinds).isSubset(of: Set(kinds)))
    }

    @Test func placeholderCannotOverwriteAValidCurrentSnapshot() {
        let live = InkAmpContinueTimelineResolver.resolve(
            loaded: vergecast,
            phase: .timeline,
            theme: .light,
        )
        let sample = ContinueWidgetSnapshot(title: "The Quiet Path", kind: .audiobook, progress: 0.56)
        let placeholder = InkAmpContinueTimelineResolver.placeholder(sample: sample)
        #expect(!live.isPlaceholder)
        #expect(live.snapshot.mediaIdentity == vergecast.mediaIdentity)
        #expect(placeholder.isPlaceholder)
        #expect(live.snapshot.mediaIdentity != placeholder.snapshot.mediaIdentity)
        #expect(
            ContinueWidgetCurrentSnapshot.select(
                shared: vergecast,
                localFallback: sample,
                sharedContainerReachable: true,
            ).mediaIdentity == vergecast.mediaIdentity
        )
    }

    @Test func progressUpdatePreservesCurrentMediaIdentity() {
        let later = ContinueWidgetSnapshot(
            title: vergecast.title,
            isPlaying: vergecast.isPlaying,
            kind: vergecast.kind,
            deepLink: vergecast.deepLink,
            progress: 0.42,
            itemID: vergecast.itemID,
        )
        #expect(later.mediaIdentity == vergecast.mediaIdentity)
        #expect(later.percentComplete != vergecast.percentComplete)
        let now = Date()
        #expect(
            !ContinueWidgetReloadPolicy.shouldReload(
                previous: vergecast,
                next: later,
                lastReload: now,
                now: now,
            )
        )
        #expect(
            ContinueWidgetReloadPolicy.shouldWrite(previous: vergecast, next: later)
        )
        #expect(
            ContinueWidgetReloadPolicy.shouldReload(
                previous: vergecast,
                next: later,
                lastReload: now.addingTimeInterval(-21),
                now: now,
            )
        )
    }

    @Test func sameTitleDifferentItemIDsReloadAndDropOldCover() {
        let first = ContinueWidgetSnapshot(
            title: "The Vergecast",
            coverFilename: "continue_cover.dat",
            isPlaying: true,
            kind: .podcast,
            deepLink: InkAmpContinueLink.continueURL.absoluteString,
            progress: 0.10,
            itemID: "pod:episode-a",
        )
        let second = ContinueWidgetSnapshot(
            title: "The Vergecast",
            isPlaying: true,
            kind: .podcast,
            deepLink: InkAmpContinueLink.continueURL.absoluteString,
            progress: 0.02,
            itemID: "pod:episode-b",
        )
        #expect(first.mediaIdentity == "pod:episode-a")
        #expect(second.mediaIdentity == "pod:episode-b")
        #expect(first.mediaIdentity != second.mediaIdentity)
        #expect(
            ContinueWidgetReloadPolicy.shouldReload(
                previous: first,
                next: second,
                lastReload: Date(),
                now: Date(),
            )
        )
        #expect(
            !ContinueWidgetSnapshot.shouldKeepPreviousCover(
                previous: first,
                nextItemID: second.itemID,
                nextTitle: second.title,
                nextKind: second.kind,
                nextDeepLink: second.deepLink,
            )
        )
        #expect(
            ContinueWidgetSnapshot.shouldKeepPreviousCover(
                previous: first,
                nextItemID: first.itemID,
                nextTitle: first.title,
                nextKind: first.kind,
                nextDeepLink: first.deepLink,
            )
        )
    }

    @Test func sessionKindMapsToStableQueueItemIDs() {
        #expect(
            ContinueWidgetItemID.from(
                sessionKind: .audiobook(BookID(sourceID: "storyteller", uuid: "troop"))
            ) == "book:storyteller/troop"
        )
        #expect(
            ContinueWidgetItemID.from(
                sessionKind: .readaloud(BookID(sourceID: "storyteller", uuid: "quiet-path"))
            ) == "book:storyteller/quiet-path"
        )
        #expect(
            ContinueWidgetItemID.from(sessionKind: .podcast("vergecast-123"))
                == "pod:vergecast-123"
        )
    }

    @Test func legacySnapshotsWithoutItemIDStillDecode() throws {
        let legacyJSON = """
            {
              "generatedAt": "2026-09-16T12:00:00Z",
              "isPlaying": true,
              "kind": "audiobook",
              "title": "The Troop"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            ContinueWidgetSnapshot.self,
            from: Data(legacyJSON.utf8),
        )
        #expect(snapshot.itemID == nil)
        #expect(snapshot.mediaIdentity.contains("The Troop"))
    }
}
