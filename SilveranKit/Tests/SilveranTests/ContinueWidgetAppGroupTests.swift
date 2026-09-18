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

    @Test func continueKindNeverCollidesWithRetiredTiles() {
        let kind = SilveranWidgetConstants.continueWidgetKind
        #expect(kind == "inkamp.continue.upnext.v1")
        #expect(kind != "InkAmpContinueWidget")
        #expect(kind != SilveranWidgetConstants.readingWidgetKind)
        // The parked static tiles must never be registered or reloaded again.
        for legacy in SilveranWidgetConstants.legacySideloadContinueWidgetKinds {
            #expect(legacy != kind)
        }
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

    @Test func upNextPaintsAtMostThree() {
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
}
