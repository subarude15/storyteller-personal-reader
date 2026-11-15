import CoreGraphics
import Foundation
@testable import SilveranAppleWidgets
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
            "inkamp.continue.light.medium.v3",
            "inkamp.continue.light.large.v1",
            "inkamp.continue.dark.medium.v3",
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
        #expect(
            SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                "inkamp.continue.light.medium.v2"
            )
        )
        #expect(
            SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                "inkamp.continue.dark.medium.v2"
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
            rate: 1,
        )
        #expect(snapshot.percentComplete == 50)
        #expect(snapshot.remainingText == "30m left")
        #expect(snapshot.progressCaption == "50% · 30m / 1h · 30m left")
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
            rate: 1,
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
        #expect(decoded.progressCaption == "56% · 4h 54m / 8h 48m · 3h 54m left")
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
            kind: "inkamp.continue.light.medium.v3",
            family: "systemMedium",
            theme: .light,
            phase: .timeline,
            isPreview: false,
            snapshot: loaded,
        )
        #expect(line.contains("getTimeline"))
        #expect(line.contains("kind=inkamp.continue.light.medium.v3"))
        #expect(line.contains("family=systemMedium"))
        #expect(line.contains("theme=light"))
        #expect(line.contains("phase=timeline"))
        #expect(line.contains("preview=false"))
        #expect(line.contains("title=\"Piranesi\""))
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
        #expect(empty.contains("getSnapshot"))
        #expect(empty.contains("title=\"nil\""))
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

@Suite("Continue widget current snapshot selection", .serialized)
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
        #expect(kinds.contains("inkamp.continue.light.medium.v3"))
        #expect(kinds.contains("inkamp.continue.dark.medium.v3"))
        #expect(kinds.contains("inkamp.continue.light.large.v1"))
        #expect(kinds.contains("inkamp.continue.dark.large.v1"))
        #expect(
            ContinueWidgetSnapshotStore.compactTimelineKinds.sorted()
                == [
                    "inkamp.continue.dark.medium.v3",
                    "inkamp.continue.light.medium.v3",
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

    @Test func mediumKindsAreV3AndLargeKindsStayV1() {
        let kinds = SilveranWidgetConstants.continueWidgetKinds
        #expect(kinds.contains(where: { $0.contains(".medium.v3") }))
        #expect(!kinds.contains(where: { $0.contains(".medium.v2") }))
        #expect(kinds[1] == "inkamp.continue.light.large.v1")
        #expect(kinds[3] == "inkamp.continue.dark.large.v1")
        #expect(
            Set(ContinueWidgetSnapshotStore.timelineKindsToReload).isSuperset(
                of: [
                    "inkamp.continue.light.medium.v3",
                    "inkamp.continue.dark.medium.v3",
                ]
            )
        )
    }

    @Test func gallerySnapshotAndHomeTimelineUseTheSameSharedSnapshot() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let current = vergecast
        let gallery = ContinueWidgetLiveUpdateBuilder.make(
            loaded: current,
            phase: .snapshot,
            theme: .dark,
            now: now,
        )
        let home = ContinueWidgetLiveUpdateBuilder.make(
            loaded: current,
            phase: .timeline,
            theme: .light,
            now: now,
        )
        #expect(gallery.snapshot == home.snapshot)
        #expect(gallery.snapshot.mediaIdentity == current.mediaIdentity)
        #expect(gallery.snapshot.itemID == "pod:vergecast-123")
        #expect(gallery.refreshAfter == nil)
        #expect(home.refreshAfter == now.addingTimeInterval(5 * 60))
        #expect(gallery.resolved.phase == .snapshot)
        #expect(home.resolved.phase == .timeline)
        #expect(!gallery.resolved.isPlaceholder)
        #expect(!home.resolved.isPlaceholder)
    }

    @Test func mediumTimelineAfterIdentitySwitchDoesNotRetainPreviousItem() {
        let now = Date(timeIntervalSince1970: 1_777_000_100)
        let afterAudiobook = ContinueWidgetLiveUpdateBuilder.make(
            loaded: troop,
            phase: .timeline,
            theme: .dark,
            now: now,
        )
        let afterPodcast = ContinueWidgetLiveUpdateBuilder.make(
            loaded: vergecast,
            phase: .timeline,
            theme: .dark,
            now: now,
        )
        #expect(afterAudiobook.snapshot.itemID == "book:storyteller/troop")
        #expect(afterPodcast.snapshot.itemID == "pod:vergecast-123")
        #expect(afterPodcast.snapshot.itemID != afterAudiobook.snapshot.itemID)
        #expect(afterPodcast.snapshot.title != "The Troop")
        #expect(afterPodcast.snapshot.title == vergecast.title)
        #expect(
            ContinueWidgetReloadPolicy.shouldReload(
                previous: afterAudiobook.snapshot,
                next: afterPodcast.snapshot,
                lastReload: now,
                now: now,
            )
        )
    }

    @Test func remainingTextAdjustsForPlaybackRate() {
        let normal = ContinueWidgetSnapshot(
            title: "Piranesi",
            progress: 0.5,
            elapsedSeconds: 1800,
            durationSeconds: 3600,
            rate: 1.0,
        )
        #expect(normal.remainingText == "30m left")

        let faster = ContinueWidgetSnapshot(
            title: "Piranesi",
            progress: 0.5,
            elapsedSeconds: 1800,
            durationSeconds: 3600,
            rate: 1.5,
        )
        #expect(faster.remainingText == "20m left")
        #expect(faster.progressCaption == "50% · 30m / 1h · 20m left")
    }

    @Test func statusBadgeReflectsKindAndPlaybackState() {
        let playingAudio = ContinueWidgetSnapshot(title: "Piranesi", isPlaying: true, kind: .audiobook)
        #expect(
            InkAmpContinueWidgetActions.statusBadge(for: playingAudio)
                == InkAmpContinueStatusBadge(label: "NOW LISTENING", symbolName: "waveform")
        )

        let playingPodcast = ContinueWidgetSnapshot(title: "Vergecast", isPlaying: true, kind: .podcast)
        #expect(
            InkAmpContinueWidgetActions.statusBadge(for: playingPodcast)
                == InkAmpContinueStatusBadge(label: "NOW PLAYING", symbolName: "waveform")
        )

        let idleEbook = ContinueWidgetSnapshot(title: "Good Energy", isPlaying: false, kind: .ebook)
        #expect(
            InkAmpContinueWidgetActions.statusBadge(for: idleEbook)
                == InkAmpContinueStatusBadge(label: "CONTINUE READING", symbolName: "book.closed.fill")
        )

        let idleReadaloud = ContinueWidgetSnapshot(title: "Dune", isPlaying: false, kind: .readaloud)
        #expect(
            InkAmpContinueWidgetActions.statusBadge(for: idleReadaloud)
                == InkAmpContinueStatusBadge(label: "CONTINUE SYNC", symbolName: "text.book.closed.fill")
        )
    }

    @Test func inlineTransportRequiresActiveNonEbookSession() {
        let liveAudio = ContinueWidgetSnapshot(
            title: "Piranesi",
            isPlaying: true,
            kind: .audiobook,
            hasLiveSession: true,
        )
        #expect(InkAmpContinueWidgetActions.showsInlineTransport(for: liveAudio))

        let pausedLivePodcast = ContinueWidgetSnapshot(
            title: "Vergecast",
            isPlaying: false,
            kind: .podcast,
            hasLiveSession: true,
        )
        #expect(InkAmpContinueWidgetActions.showsInlineTransport(for: pausedLivePodcast))

        let ebookWithStaleLiveFlag = ContinueWidgetSnapshot(
            title: "Good Energy",
            isPlaying: false,
            kind: .ebook,
            hasLiveSession: true,
        )
        #expect(!InkAmpContinueWidgetActions.showsInlineTransport(for: ebookWithStaleLiveFlag))

        let coldAudio = ContinueWidgetSnapshot(
            title: "Piranesi",
            isPlaying: false,
            kind: .audiobook,
            hasLiveSession: false,
        )
        #expect(!InkAmpContinueWidgetActions.showsInlineTransport(for: coldAudio))
    }

    @Test func liveSessionPriorityYieldsWhenPausedAndNewerEbookIsActive() {
        #expect(
            ContinueWidgetSnapshot.shouldPreferLiveSession(
                sessionIsPlaying: true,
                sessionItemID: "book:storyteller/troop",
                homeItemID: "book:storyteller/ebook-1",
            )
        )
        #expect(
            !ContinueWidgetSnapshot.shouldPreferLiveSession(
                sessionIsPlaying: false,
                sessionItemID: "book:storyteller/troop",
                homeItemID: "book:storyteller/ebook-1",
            )
        )
        #expect(
            ContinueWidgetSnapshot.shouldPreferLiveSession(
                sessionIsPlaying: false,
                sessionItemID: "book:storyteller/troop",
                homeItemID: "book:storyteller/troop",
            )
        )
        #expect(
            ContinueWidgetSnapshot.shouldPreferLiveSession(
                sessionIsPlaying: false,
                sessionItemID: "book:storyteller/troop",
                homeItemID: nil,
            )
        )
    }

    @Test func upNextItemProgressAndKindSymbols() {
        let item = ContinueWidgetQueueItem(
            id: "book:storyteller/1",
            title: "Book 1",
            kind: .readaloud,
            deepLink: "punkrally://continue?item=book:storyteller/1",
            progress: 0.42,
        )
        #expect(item.clampedProgress == 0.42)
        #expect(item.percentComplete == 42)
        #expect(item.kind?.symbolName == "text.book.closed.fill")
        #expect(ContinueWidgetKindTag.ebook.symbolName == "book.closed.fill")
        #expect(ContinueWidgetKindTag.audiobook.symbolName == "headphones")
        #expect(ContinueWidgetKindTag.podcast.symbolName == "mic.fill")
    }

    @Test func concurrentPublishPreservesFresherStreakAcrossAudioHomeRace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PausableContinueWidgetFileStore(root: root)
        defer {
            store.resetAndRelease()
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }

        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: false,
            kind: .ebook,
            coverData: nil,
            streakDays: 3,
            streakActivityDayKey: "2026-11-14",
            fileStore: store
        )
        #expect(store.readSnapshot(in: root)?.streakDays == 3)

        store.pauseNextRead()
        let audioDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // Audio tick: nil streak should preserve whatever it read.
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: true,
                kind: .audiobook,
                coverData: nil,
                hasLiveSession: true,
                streakDays: nil,
                streakActivityDayKey: nil,
                fileStore: store
            )
            audioDone.signal()
        }
        try store.waitForPausedRead()
        // Home publishes a fresher streak while audio still holds the publish lock.
        store.expectContenderPublish()
        let homeDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: false,
                kind: .ebook,
                coverData: nil,
                streakDays: 5,
                streakActivityDayKey: "2026-11-15",
                fileStore: store
            )
            homeDone.signal()
        }
        try store.waitForContenderPublish()
        // Without an atomic publish lock, home would finish first and audio would
        // overwrite streak 5 with the stale preserved 3 after resume.
        Thread.sleep(forTimeInterval: 0.05)
        store.resumePausedRead()
        #expect(audioDone.wait(timeout: .now() + 10) == .success)
        #expect(homeDone.wait(timeout: .now() + 10) == .success)

        let final = store.readSnapshot(in: root)
        #expect(final?.streakDays == 5)
        #expect(final?.streakActivityDayKey == "2026-11-15")
    }

    @Test func paintSignatureTracksProgressTimingStreakAndExcludesGeneratedAt() {
        let base = ContinueWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: false,
            kind: .audiobook,
            progress: 0.25,
            elapsedSeconds: 900,
            durationSeconds: 3600,
            hasLiveSession: true,
            rate: 1,
            streakDays: 2,
            streakActivityDayKey: "2026-11-14"
        )
        var laterStamp = base
        laterStamp.generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(base.paintSignature == laterStamp.paintSignature)

        var progressChanged = base
        progressChanged.progress = 0.5
        #expect(progressChanged.paintSignature != base.paintSignature)

        var timingChanged = base
        timingChanged.elapsedSeconds = 1800
        #expect(timingChanged.paintSignature != base.paintSignature)

        var streakChanged = base
        streakChanged.streakDays = 5
        #expect(streakChanged.paintSignature != base.paintSignature)
    }

    @Test func publishLiveMirrorSeamPreservesFresherHomeStreakDuringAudioRace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-live-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PausableContinueWidgetFileStore(root: root)
        defer {
            store.resetAndRelease()
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }

        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: false,
            kind: .ebook,
            coverData: nil,
            streakDays: 3,
            streakActivityDayKey: "2026-11-14",
            fileStore: store
        )

        store.pauseNextRead()
        let audioDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // Real publisher/audio seam: no pre-read streak re-assert.
            ContinueWidgetSnapshotStore.publishLiveMirror(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: true,
                kind: .audiobook,
                coverData: nil,
                hasLiveSession: true,
                fileStore: store
            )
            audioDone.signal()
        }
        try store.waitForPausedRead()
        store.expectContenderPublish()
        let homeDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: false,
                kind: .ebook,
                coverData: nil,
                streakDays: 7,
                streakActivityDayKey: "2026-11-15",
                fileStore: store
            )
            homeDone.signal()
        }
        try store.waitForContenderPublish()
        Thread.sleep(forTimeInterval: 0.05)
        store.resumePausedRead()
        #expect(audioDone.wait(timeout: .now() + 10) == .success)
        #expect(homeDone.wait(timeout: .now() + 10) == .success)

        let final = store.readSnapshot(in: root)
        #expect(final?.streakDays == 7)
        #expect(final?.streakActivityDayKey == "2026-11-15")
    }

    @Test func authoritativeStreakRetriesAfterSnapshotBecomesAvailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }
        let store = PausableContinueWidgetFileStore(root: root)
        #expect(!ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 1, streakActivityDayKey: "2026-11-15", fileStore: store
        ))
        ContinueWidgetSnapshotStore.publish(
            title: "Book", subtitle: nil, isPlaying: false, kind: .ebook,
            coverData: nil, fileStore: store
        )
        #expect(ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 1, streakActivityDayKey: "2026-11-15", fileStore: store
        ))
        #expect(store.readSnapshot(in: root)?.streakDays == 1)
    }

    @Test func unchangedPaintPersistsRawRateAndTiming() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }
        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi", subtitle: nil, isPlaying: false, kind: .audiobook,
            coverData: nil, progress: 0.1, elapsedSeconds: 60,
            durationSeconds: 600, rate: 1, fileStore: store
        )
        let before = try #require(store.readSnapshot(in: root))
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi", subtitle: nil, isPlaying: false, kind: .audiobook,
            coverData: nil, progress: 0.101, elapsedSeconds: 61,
            durationSeconds: 600, rate: 0.999, fileStore: store
        )
        let after = try #require(store.readSnapshot(in: root))
        #expect(before.paintSignature == after.paintSignature)
        #expect(after.rate == 0.999)
        #expect(after.elapsedSeconds == 61)
        #expect(after.progress == 0.101)
    }

    @Test func unchangedPaintPersistsNewStreakAnchor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }
        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        for anchor in ["2026-11-10", "2026-11-15"] {
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi", subtitle: "Clarke", isPlaying: false,
                kind: .ebook, coverData: nil, streakDays: 1,
                streakActivityDayKey: anchor, fileStore: store
            )
        }
        let saved = try #require(store.readSnapshot(in: root))
        #expect(saved.streakDays == 1)
        #expect(saved.streakActivityDayKey == "2026-11-15")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        #expect(saved.resolvingStreak(at: today, calendar: calendar).streakDays == 1)
    }

    @Test func continueWidgetPublisherSourceDoesNotPreassertStoredStreak() throws {
        let publisherURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppleKit/MobileDesktop/ContinueWidgetPublisher.swift")
        let source = try String(contentsOf: publisherURL, encoding: .utf8)
        #expect(source.contains("publishLiveMirror("))
        #expect(!source.contains("streakDays: last.streakDays"))
        #expect(!source.contains("streakActivityDayKey: last.streakActivityDayKey"))
        #expect(!source.contains("streakDays: streakDays ?? last.streakDays"))
        // iOS-only publisher is not a SwiftPM macOS runtime target. This source
        // integration check complements store behavior tests; it is not device QA.
        let sessionBody = try #require(source.components(
            separatedBy: "private static func publishSession("
        ).last?.components(separatedBy: "private static func handleToggleFromWidget(").first)
        let refresh = try #require(sessionBody.range(of: "let streak = authoritativeStreakProvider?()"))
        let write = try #require(sessionBody.range(
            of: "ContinueWidgetSnapshotStore.publishLiveMirror(", options: .backwards
        ))
        #expect(refresh.lowerBound < write.lowerBound)
        #expect(!sessionBody[refresh.lowerBound..<write.lowerBound].contains("await "))
    }

    @Test func updateAuthoritativeStreakPreservesItemTimingAndNoopsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-streak-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }
        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: true,
            kind: .audiobook,
            coverData: Data([0x01, 0x02]),
            progress: 0.42,
            elapsedSeconds: 900,
            durationSeconds: 3600,
            hasLiveSession: true,
            rate: 1.25,
            streakDays: 0,
            streakActivityDayKey: "2026-11-10",
            fileStore: store
        )
        let before = try #require(store.readSnapshot(in: root))

        ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 3,
            streakActivityDayKey: "2026-11-15",
            fileStore: store
        )
        let updated = try #require(store.readSnapshot(in: root))
        #expect(updated.streakDays == 3)
        #expect(updated.streakActivityDayKey == "2026-11-15")
        #expect(updated.title == before.title)
        #expect(updated.subtitle == before.subtitle)
        #expect(updated.isPlaying == before.isPlaying)
        #expect(updated.kind == before.kind)
        #expect(updated.progress == before.progress)
        #expect(updated.elapsedSeconds == before.elapsedSeconds)
        #expect(updated.durationSeconds == before.durationSeconds)
        #expect(updated.rate == before.rate)
        #expect(updated.hasLiveSession == before.hasLiveSession)
        #expect(updated.coverFilename == before.coverFilename)

        let generatedAt = updated.generatedAt
        ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 3,
            streakActivityDayKey: "2026-11-15",
            fileStore: store
        )
        let unchanged = try #require(store.readSnapshot(in: root))
        #expect(unchanged.generatedAt == generatedAt)
        #expect(unchanged.streakDays == 3)

        // Same count, new activity anchor still publishes.
        ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 3,
            streakActivityDayKey: "2026-11-16",
            fileStore: store
        )
        let reanchored = try #require(store.readSnapshot(in: root))
        #expect(reanchored.streakDays == 3)
        #expect(reanchored.streakActivityDayKey == "2026-11-16")
        #expect(reanchored.progress == 0.42)
        #expect(reanchored.rate == 1.25)
        #expect(ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 0, streakActivityDayKey: "2026-11-16", fileStore: store
        ))
        let corrected = try #require(store.readSnapshot(in: root))
        #expect(corrected.streakDays == 0)
        #expect(corrected.progress == 0.42)
        #expect(corrected.rate == 1.25)
    }

    @Test func sessionTrackerSourcePublishesStreakIndependentOfNotificationOptIn() throws {
        let trackerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("XCodeApps/PunkRallyModules/Stats/SessionTracker.swift")
        let source = try String(contentsOf: trackerURL, encoding: .utf8)
        let syncBody = try #require(source.components(
            separatedBy: "func applyMergedSyncDocument("
        ).last?.components(separatedBy: "/// Prune sessions").first)
        #expect(syncBody.contains("publishAuthoritativeStreakIfNeeded(force: true)"))
        #expect(source.contains("updateAuthoritativeStreak("))
        #expect(source.contains("publishAuthoritativeStreakIfNeeded"))
        #expect(source.contains("shouldRunCadence("))
        #expect(source.contains("shouldReconcileNotificationsOnTick("))
        #expect(source.contains("shouldPublishAuthoritativeStreak("))
        #expect(source.contains("hasActiveSession: self.activeSession != nil"))
        #expect(source.contains("notificationsEnabled: ReadingMotivationStore.shared.settings.notificationsEnabled"))
    }

    @Test func streakWidgetKindIsUniqueAndExcludedFromContinueKinds() {
        let streakKind = SilveranWidgetConstants.streakWidgetKind
        #expect(streakKind == "inkamp.streak.medium.v1")
        #expect(!SilveranWidgetConstants.continueWidgetKinds.contains(streakKind))
        #expect(streakKind != SilveranWidgetConstants.readingWidgetKind)
        #expect(ContinueWidgetSnapshotStore.timelineKindsToReload == SilveranWidgetConstants.continueWidgetKinds)
    }

    @Test func streakGoalPresentationCoversFiveTiersAndEveningUrgency() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let daytime = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 14, minute: 0
        )))
        let evening = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 20, minute: 15
        )))

        func makeSnapshot(minutes: Double, goal: Int = 30, streak: Int = 4, longest: Int = 9) -> ContinueWidgetSnapshot {
            ContinueWidgetSnapshot(
                generatedAt: daytime,
                title: "Piranesi",
                subtitle: "Susanna Clarke",
                kind: .audiobook,
                streakDays: streak,
                streakActivityDayKey: "2026-11-15",
                todayActiveSeconds: minutes * 60,
                dailyGoalMinutes: goal,
                todayGoalDayKey: "2026-11-15",
                longestStreakDays: longest
            )
        }

        // 0% -> Critical Red
        let tier0 = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 0), now: daytime, calendar: calendar)
        #expect(tier0.tier == .criticalRed)
        #expect(tier0.isEveningUrgent == false)
        #expect(tier0.countdownHeadline == "30m to go")
        #expect(tier0.todayRatioText == "0/30m today")

        // 10% (3/30) -> Sparked Orange
        let tier1 = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 3), now: daytime, calendar: calendar)
        #expect(tier1.tier == .sparked)
        #expect(tier1.countdownHeadline == "27m to go")
        #expect(tier1.todayRatioText == "3/30m today")

        // 33% (10/30) -> Rolling Amber
        let tier2 = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 10), now: daytime, calendar: calendar)
        #expect(tier2.tier == .rolling)
        #expect(tier2.countdownHeadline == "20m to go")

        // 60% (18/30) -> Home Stretch Aqua
        let tier3 = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 18), now: daytime, calendar: calendar)
        #expect(tier3.tier == .homeStretch)
        #expect(tier3.countdownHeadline == "12m to go")
        #expect(tier3.streakBadgeText == "🔥 4d streak · Best 9d")

        // 100%+ (32/30) -> Completed Green (even at night)
        let tier4 = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 32, streak: 5, longest: 5), now: evening, calendar: calendar)
        #expect(tier4.tier == .completed)
        #expect(tier4.isEveningUrgent == false)
        #expect(tier4.countdownHeadline == "Goal done!")
        #expect(tier4.streakBadgeText == "🔥 5-day streak")

        // Evening urgency: >= 20:00 and < 50% escalates to Critical Red
        let eveningLagging = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 10), now: evening, calendar: calendar)
        #expect(eveningLagging.tier == .criticalRed)
        #expect(eveningLagging.isEveningUrgent == true)
        #expect(eveningLagging.statusSubline == "Midnight closes in")

        // Evening >= 50% stays Home Stretch Aqua
        let eveningOnTrack = InkAmpStreakGoalPresentation.resolve(from: makeSnapshot(minutes: 18), now: evening, calendar: calendar)
        #expect(eveningOnTrack.tier == .homeStretch)
        #expect(eveningOnTrack.isEveningUrgent == false)
    }

    @Test func resolvingStreakResetsTodayActiveSecondsOnNewDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let yesterday = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 14, hour: 21, minute: 0
        )))
        let todayMorning = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 15, hour: 8, minute: 0
        )))

        let snapshot = ContinueWidgetSnapshot(
            generatedAt: yesterday,
            title: "Piranesi",
            kind: .audiobook,
            streakDays: 4,
            streakActivityDayKey: "2026-11-14",
            todayActiveSeconds: 22 * 60,
            dailyGoalMinutes: 30,
            todayGoalDayKey: "2026-11-14",
            longestStreakDays: 12
        )

        let resolved = snapshot.resolvingStreak(at: todayMorning, calendar: calendar)
        #expect(resolved.streakDays == 4)
        #expect(resolved.todayActiveSeconds == 0)
        #expect(resolved.todayGoalDayKey == "2026-11-15")
        let goal = InkAmpStreakGoalPresentation.resolve(from: snapshot, now: todayMorning, calendar: calendar)
        #expect(goal.doneMinutes == 0)
        #expect(goal.minutesLeft == 30)
        #expect(goal.tier == .criticalRed)
        #expect(goal.streakDays == 4)
    }

    @Test func publishAndUpdateAuthoritativeStreakPersistAndPreserveGoalFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("streak-widget-fields-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }
        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()

        ContinueWidgetSnapshotStore.publish(
            title: "The Reddening",
            subtitle: "Adam Nevill",
            isPlaying: false,
            kind: .audiobook,
            coverData: Data([0x01, 0x02]),
            progress: 0.25,
            elapsedSeconds: 600,
            durationSeconds: 2400,
            hasLiveSession: true,
            streakDays: 3,
            streakActivityDayKey: "2026-11-15",
            todayActiveSeconds: 15 * 60,
            dailyGoalMinutes: 30,
            todayGoalDayKey: "2026-11-15",
            longestStreakDays: 7,
            fileStore: store
        )

        // Live audio tick omitting goal/streak preserves existing authoritative values.
        ContinueWidgetSnapshotStore.publishLiveMirror(
            title: "The Reddening",
            subtitle: "Adam Nevill",
            isPlaying: true,
            kind: .audiobook,
            coverData: nil,
            progress: 0.30,
            elapsedSeconds: 720,
            durationSeconds: 2400,
            hasLiveSession: true,
            fileStore: store
        )
        let afterAudio = try #require(store.readSnapshot(in: root))
        #expect(afterAudio.todayActiveSeconds == 15 * 60)
        #expect(afterAudio.dailyGoalMinutes == 30)
        #expect(afterAudio.todayGoalDayKey == "2026-11-15")
        #expect(afterAudio.longestStreakDays == 7)

        // Authoritative goal update advances today's seconds and goal without losing item timing.
        let updatedOK = ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: 4,
            streakActivityDayKey: "2026-11-15",
            todayActiveSeconds: 24 * 60,
            dailyGoalMinutes: 45,
            todayGoalDayKey: "2026-11-15",
            longestStreakDays: 8,
            fileStore: store
        )
        #expect(updatedOK)
        let afterGoalUpdate = try #require(store.readSnapshot(in: root))
        #expect(afterGoalUpdate.streakDays == 4)
        #expect(afterGoalUpdate.todayActiveSeconds == 24 * 60)
        #expect(afterGoalUpdate.dailyGoalMinutes == 45)
        #expect(afterGoalUpdate.longestStreakDays == 8)
        #expect(afterGoalUpdate.progress == 0.30)
        #expect(afterGoalUpdate.isPlaying == true)
    }
}

/// Directory-backed Continue publish seam with a suspension point on snapshot read.
private final class PausableContinueWidgetFileStore: ContinueWidgetSnapshotFileStoring, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var pauseRead = false
    private var awaitingContender = false
    private let readStarted = DispatchSemaphore(value: 0)
    private let readGate = DispatchSemaphore(value: 0)
    private let contenderEntered = DispatchSemaphore(value: 0)

    init(root: URL) { self.root = root }

    func resolveContainer() -> URL? {
        lock.lock()
        let shouldSignalContender = awaitingContender
        if shouldSignalContender { awaitingContender = false }
        lock.unlock()
        if shouldSignalContender {
            contenderEntered.signal()
        }
        return root
    }

    func ensureDirectories(in container: URL) throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: ContinueWidgetSnapshotStore.coversDirectory(in: container),
            withIntermediateDirectories: true
        )
    }

    func readSnapshot(in container: URL) -> ContinueWidgetSnapshot? {
        lock.lock()
        let shouldPause = pauseRead
        if shouldPause { pauseRead = false }
        lock.unlock()
        if shouldPause {
            readStarted.signal()
            let released = readGate.wait(timeout: .now() + 10)
            #expect(released == .success, "Paused snapshot read was not released within 10 seconds")
        }
        return ContinueWidgetSnapshotStore.readSnapshotFile(in: container)
    }

    func writeSnapshotData(_ data: Data, to container: URL) throws {
        try data.write(
            to: ContinueWidgetSnapshotStore.snapshotURL(in: container),
            options: [.atomic]
        )
    }

    func existingCoverFilename(in container: URL) -> String? {
        ContinueWidgetSnapshotStore.readSnapshotFile(in: container)?.coverFilename
    }

    func writeCoverData(_ data: Data, to container: URL) throws -> String {
        let name = "continue_cover.dat"
        let url = ContinueWidgetSnapshotStore.coversDirectory(in: container)
            .appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return name
    }

    func pauseNextRead() {
        lock.lock()
        pauseRead = true
        lock.unlock()
    }

    func waitForPausedRead() throws {
        try #require(
            readStarted.wait(timeout: .now() + 10) == .success,
            "Publish never reached its snapshot-read suspension point within 10 seconds"
        )
    }

    func expectContenderPublish() {
        lock.lock()
        awaitingContender = true
        lock.unlock()
    }

    func waitForContenderPublish() throws {
        try #require(
            contenderEntered.wait(timeout: .now() + 10) == .success,
            "Contending publish never entered resolveContainer within 10 seconds"
        )
    }

    func resumePausedRead() {
        readGate.signal()
    }

    func resetAndRelease() {
        lock.lock()
        let wasPaused = pauseRead
        let wasAwaitingContender = awaitingContender
        pauseRead = false
        awaitingContender = false
        lock.unlock()
        if wasPaused {
            readStarted.signal()
        }
        if wasAwaitingContender {
            contenderEntered.signal()
        }
        readGate.signal()
    }
}
