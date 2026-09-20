import Foundation
import Testing

@testable import SilveranKit

@Suite("Request activity notifications")
struct RequestActivityNotificationTests {
    // MARK: - Available transitions

    @Test func wantedToAvailableInLibraryNotifies() {
        let previous = item(status: .wanted, formats: [.ebook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.count == 1)
        guard case .available(_, let title, let formats) = events[0] else {
            Issue.record("expected available event")
            return
        }
        #expect(title == "Dune")
        #expect(formats == [.ebook])
        #expect(events[0].notificationTitle == "Book ready")
        #expect(events[0].notificationBody == "Dune ebook is now available in your library.")
    }

    @Test func availableInLibraryStayDoesNotNotify() {
        let previous = item(status: .availableInLibrary, formats: [.ebook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.isEmpty)
    }

    @Test func ebookOnlyArrival() {
        let previous = item(status: .wanted, formats: [.ebook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.map(\.identifier) == ["request.\(previous.id).available.ebook"])
    }

    @Test func audiobookOnlyArrival() {
        let previous = item(status: .snatched, formats: [.audiobook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.audiobook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.count == 1)
        #expect(events[0].notificationBody == "Dune audiobook is now available in your library.")
        #expect(events[0].identifier == "request.\(previous.id).available.audiobook")
    }

    @Test func ebookThenAudiobookSeparateUpdatesNotifyTwice() {
        let id = "req-1"
        var state = RequestActivityNotificationState()

        // ebook arrives
        let wantedBoth = item(
            id: id,
            statuses: [.ebook: .wanted, .audiobook: .wanted],
        )
        let ebookReady = item(
            id: id,
            statuses: [.ebook: .availableInLibrary, .audiobook: .wanted],
        )
        let first = RequestActivityTransitionDetector.events(
            previous: wantedBoth,
            current: ebookReady,
            settings: enabledSettings(),
        )
        #expect(first.count == 1)
        let afterFirst = RequestActivityTransitionDetector.applyingNotificationState(
            ebookReady,
            events: first,
            previous: wantedBoth,
        )
        state = afterFirst.notificationState ?? state
        #expect(state.lastNotifiedAvailableFormats == [.ebook])

        // audiobook arrives later
        let bothReady = item(
            id: id,
            statuses: [.ebook: .availableInLibrary, .audiobook: .availableInLibrary],
            notificationState: state,
        )
        let second = RequestActivityTransitionDetector.events(
            previous: afterFirst,
            current: bothReady,
            settings: enabledSettings(),
        )
        #expect(second.count == 1)
        guard case .available(_, _, let formats) = second[0] else {
            Issue.record("expected available")
            return
        }
        #expect(formats == [.audiobook])
        #expect(second[0].identifier == "request.\(id).available.audiobook")
    }

    @Test func bothFormatsArrivingSimultaneouslyCoalesceToOneNotification() {
        let previous = item(
            statuses: [.ebook: .wanted, .audiobook: .wanted],
        )
        let current = item(
            id: previous.id,
            statuses: [.ebook: .availableInLibrary, .audiobook: .availableInLibrary],
        )
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.count == 1)
        guard case .available(_, _, let formats) = events[0] else {
            Issue.record("expected available")
            return
        }
        #expect(Set(formats) == [.ebook, .audiobook])
        #expect(events[0].identifier == "request.\(previous.id).available.both")
        #expect(events[0].notificationBody == "Dune is now available in your library.")
    }

    @Test func providerAvailableToAvailableInLibraryNotifies() {
        let previous = item(status: .available, formats: [.ebook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.count == 1)
    }

    @Test func providerAvailableStayingProviderOnlyDoesNotNotify() {
        let previous = item(status: .available, formats: [.ebook])
        let current = item(id: previous.id, status: .available, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.isEmpty)
    }

    // MARK: - Attention transitions

    @Test func searchingToNeedsAttentionNotifies() {
        let previous = item(status: .searching, formats: [.ebook])
        let current = item(
            id: previous.id,
            status: .needsAttention,
            formats: [.ebook],
            attention: "Still waiting",
        )
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.count == 1)
        #expect(events[0].notificationTitle == "Book request needs attention")
        #expect(events[0].notificationBody == "Dune ebook needs attention.")
        #expect(!events[0].notificationBody.contains("Still waiting"))
    }

    @Test func needsAttentionStayDoesNotDuplicate() {
        let previous = item(
            status: .needsAttention,
            formats: [.ebook],
            attention: "Still waiting",
            notificationState: RequestActivityNotificationState(
                lastNotifiedAttentionFingerprint: "ebook"
            ),
        )
        let current = item(
            id: previous.id,
            status: .needsAttention,
            formats: [.ebook],
            attention: "Still waiting",
            notificationState: previous.notificationState,
        )
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.isEmpty)
    }

    @Test func temporaryLookupFailureWithoutNeedsAttentionDoesNotNotify() {
        // Searching with a lastError but status not escalated.
        let previous = item(status: .searching, formats: [.ebook])
        var current = item(id: previous.id, status: .searching, formats: [.ebook])
        current.lastError = "Timed out"
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.isEmpty)
    }

    @Test func needsAttentionThenSearchingThenNeedsAttentionNotifiesAgain() {
        let id = "attn-1"
        let searching = item(id: id, status: .searching, formats: [.audiobook])
        let attention = item(
            id: id,
            status: .needsAttention,
            formats: [.audiobook],
            attention: "lookup failed",
        )
        let first = RequestActivityTransitionDetector.events(
            previous: searching,
            current: attention,
            settings: enabledSettings(),
        )
        #expect(first.count == 1)
        let stamped = RequestActivityTransitionDetector.applyingNotificationState(
            attention,
            events: first,
            previous: searching,
        )
        #expect(stamped.notificationState?.lastNotifiedAttentionFingerprint == "audiobook")

        let recovered = RequestActivityTransitionDetector.applyingNotificationState(
            searching,
            events: [],
            previous: stamped,
        )
        #expect(recovered.notificationState?.lastNotifiedAttentionFingerprint == nil)

        let again = RequestActivityTransitionDetector.events(
            previous: recovered,
            current: attention,
            settings: enabledSettings(),
        )
        #expect(again.count == 1)
        #expect(again[0].notificationBody == "Dune audiobook needs attention.")
    }

    @Test func shelfarrRequestedForFiveDaysDoesNotNotifyAttention() {
        let fiveDaysAgo = Date().addingTimeInterval(-(5 * 24 * 3600))
        let item = RequestActivityItem(
            id: "shelf-1",
            canonicalWorkID: "/works/OL1W",
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            requestedFormats: [.ebook],
            createdAt: fiveDaysAgo,
            updatedAt: fiveDaysAgo,
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .requested, updatedAt: fiveDaysAgo)
            ],
        )
        // Age alone must not escalate Shelfarr — Attention.apply skips shelfarr stale.
        let after = RequestActivityAttention.apply(item, now: Date())
        #expect(after.status(for: .ebook)?.status == .requested)
        let events = RequestActivityTransitionDetector.events(
            previous: item,
            current: after,
            settings: enabledSettings(),
        )
        #expect(events.isEmpty)
    }

    // MARK: - Permission / settings

    @Test func notificationsDisabledSkipsScheduling() {
        let previous = item(status: .wanted, formats: [.ebook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: RequestNotificationSettingsSnapshot(enabled: false),
        )
        #expect(events.isEmpty)
    }

    @Test func availableNotificationsDisabledSkipsAvailableOnly() {
        let previous = item(status: .wanted, formats: [.ebook])
        let current = item(id: previous.id, status: .availableInLibrary, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: RequestNotificationSettingsSnapshot(
                enabled: true,
                notifyAvailable: false,
                notifyNeedsAttention: true,
            ),
        )
        #expect(events.isEmpty)
    }

    @Test func attentionNotificationsDisabledSkipsAttentionOnly() {
        let previous = item(status: .searching, formats: [.ebook])
        let current = item(id: previous.id, status: .needsAttention, formats: [.ebook])
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: RequestNotificationSettingsSnapshot(
                enabled: true,
                notifyAvailable: true,
                notifyNeedsAttention: false,
            ),
        )
        #expect(events.isEmpty)
    }

    // MARK: - Persistence / store

    @Test func reloadAlreadyNotifiedAvailableDoesNotDuplicate() {
        let defaults = UserDefaults(suiteName: "request-notify-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let recorder = RecordingRequestNotificationScheduler()
        let previousScheduler = RequestActivityNotifier.shared.scheduler
        let previousSettings = RequestActivityNotifier.shared.settingsProvider
        RequestActivityNotifier.shared.scheduler = recorder
        RequestActivityNotifier.shared.settingsProvider = { enabledSettings() }
        defer {
            RequestActivityNotifier.shared.scheduler = previousScheduler
            RequestActivityNotifier.shared.settingsProvider = previousSettings
        }

        let wanted = item(status: .wanted, formats: [.ebook])
        store.upsert(wanted)
        recorder.reset()

        var ready = item(id: wanted.id, status: .availableInLibrary, formats: [.ebook])
        store.upsert(ready)
        #expect(recorder.events.count == 1)

        // Simulate restart: reload from defaults and upsert same available state.
        recorder.reset()
        let reloaded = store.item(id: wanted.id)
        #expect(reloaded != nil)
        ready = reloaded!
        store.upsert(ready)
        #expect(recorder.events.isEmpty)
    }

    @Test func legacyRequestActivityItemWithoutNotificationMetadataDecodes() throws {
        let json = """
            {
              "id": "legacy-notify-1",
              "canonicalWorkID": "/works/OL1W",
              "title": "Dune",
              "author": "Frank Herbert",
              "provider": "lazyLibrarian",
              "requestedFormats": ["ebook"],
              "createdAt": "2024-01-01T00:00:00Z",
              "updatedAt": "2024-01-02T00:00:00Z",
              "formatStatuses": [
                {
                  "format": "ebook",
                  "status": "wanted",
                  "updatedAt": "2024-01-02T00:00:00Z",
                  "consecutiveLookupFailures": 0
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RequestActivityItem.self, from: Data(json.utf8))
        #expect(decoded.notificationState == nil)
        #expect(decoded.title == "Dune")
    }

    // MARK: - Identifiers / privacy

    @Test func deterministicNotificationIdentifiers() {
        let id = "abc-123"
        #expect(
            RequestNotificationIdentifiers.available(requestID: id, formats: [.ebook])
                == "request.abc-123.available.ebook"
        )
        #expect(
            RequestNotificationIdentifiers.available(requestID: id, formats: [.audiobook])
                == "request.abc-123.available.audiobook"
        )
        #expect(
            RequestNotificationIdentifiers.available(
                requestID: id,
                formats: [.ebook, .audiobook],
            ) == "request.abc-123.available.both"
        )
        #expect(
            RequestNotificationIdentifiers.attention(requestID: id)
                == "request.abc-123.attention"
        )
    }

    @Test func notificationPayloadOmitsSecretsAndBackendErrors() {
        let secret = "super-secret-api-key"
        let previous = item(status: .searching, formats: [.ebook])
        var current = item(
            id: previous.id,
            status: .needsAttention,
            formats: [.ebook],
            attention: "HTTP 401 \(secret) at https://lazy.example/api",
        )
        current.providerBookID = "LL-BOOK-999"
        current.lastError = "Bearer \(secret)"
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: current,
            settings: enabledSettings(),
        )
        #expect(events.count == 1)
        let event = events[0]
        #expect(!event.notificationBody.contains(secret))
        #expect(!event.notificationBody.contains("HTTP"))
        #expect(!event.notificationBody.contains("Bearer"))
        #expect(!event.notificationBody.contains("https://"))
        #expect(!event.identifier.contains(secret))
        #expect(!event.identifier.contains("LL-BOOK"))
        #expect(event.userInfo["requestID"] == previous.id)
        #expect(event.userInfo.keys.sorted() == ["kind", "requestID"])
    }

    @Test func recordingSchedulerDoesNotTouchSystemCenter() {
        let recorder = RecordingRequestNotificationScheduler()
        let event = RequestNotificationEvent.available(
            requestID: "r1",
            title: "Dune",
            formats: [.ebook],
        )
        recorder.schedule(event)
        #expect(recorder.events == [event])
    }

    @Test func storeDeliversOutsideLockWithoutDeadlock() {
        let defaults = UserDefaults(suiteName: "request-notify-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let recorder = RecordingRequestNotificationScheduler()
        let previousScheduler = RequestActivityNotifier.shared.scheduler
        let previousSettings = RequestActivityNotifier.shared.settingsProvider
        RequestActivityNotifier.shared.scheduler = recorder
        RequestActivityNotifier.shared.settingsProvider = { enabledSettings() }
        defer {
            RequestActivityNotifier.shared.scheduler = previousScheduler
            RequestActivityNotifier.shared.settingsProvider = previousSettings
        }

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: .requestActivityStoreDidChange,
            object: nil,
            queue: nil,
        ) { _ in
            observed = store.allItems().count
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let wanted = item(status: .wanted, formats: [.ebook])
        store.upsert(wanted)
        store.upsert(item(id: wanted.id, status: .availableInLibrary, formats: [.ebook]))
        #expect(observed == 1)
        #expect(recorder.events.count == 1)
    }

    // MARK: - Helpers

    private func enabledSettings() -> RequestNotificationSettingsSnapshot {
        RequestNotificationSettingsSnapshot(
            enabled: true,
            notifyAvailable: true,
            notifyNeedsAttention: true,
        )
    }

    private func item(
        id: String = UUID().uuidString,
        status: RequestActivityStatus,
        formats: [BookRequestFormat],
        attention: String? = nil,
        notificationState: RequestActivityNotificationState? = nil,
    ) -> RequestActivityItem {
        let now = Date()
        return RequestActivityItem(
            id: id,
            canonicalWorkID: "/works/OL1W",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: formats,
            updatedAt: now,
            formatStatuses: formats.map {
                RequestFormatStatus(format: $0, status: status, updatedAt: now)
            },
            attentionReason: attention,
            notificationState: notificationState,
        )
    }

    private func item(
        id: String = UUID().uuidString,
        statuses: [BookRequestFormat: RequestActivityStatus],
        notificationState: RequestActivityNotificationState? = nil,
    ) -> RequestActivityItem {
        let now = Date()
        let formats = BookRequestFormat.allCases.filter { statuses[$0] != nil }
        return RequestActivityItem(
            id: id,
            canonicalWorkID: "/works/OL1W",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: formats,
            updatedAt: now,
            formatStatuses: formats.map {
                RequestFormatStatus(format: $0, status: statuses[$0]!, updatedAt: now)
            },
            notificationState: notificationState,
        )
    }
}
