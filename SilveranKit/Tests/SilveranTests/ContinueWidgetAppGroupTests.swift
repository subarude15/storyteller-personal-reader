import CoreGraphics
import Foundation
import SilveranAppleWidgets
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

    @Test func fourContinueKindsAreUniqueAndNotLegacy() {
        let kinds = SilveranWidgetConstants.continueWidgetKinds
        #expect(kinds.count == 4)
        #expect(Set(kinds).count == 4)
        #expect(kinds == [
            "inkamp.continue.light.medium.v1",
            "inkamp.continue.light.large.v1",
            "inkamp.continue.dark.medium.v1",
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
}
