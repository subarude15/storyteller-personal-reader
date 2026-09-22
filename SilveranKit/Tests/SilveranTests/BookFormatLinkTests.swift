import Foundation
import Testing

@testable import SilveranKit

@Suite("Book format links")
struct BookFormatLinkTests {
    @Test func ranksPunctuationCaseAndSubtitleWithoutAutoLinking() {
        let close = makeBook(
            uuid: "audio-close",
            title: "the hobbit",
            authors: ["J.R.R. Tolkien"],
            audiobook: true,
        )
        let subtitle = makeBook(
            uuid: "audio-sub",
            title: "The Hobbit: An Unexpected Journey",
            authors: ["J.R.R. Tolkien"],
            audiobook: true,
        )
        let otherEdition = makeBook(
            uuid: "audio-edition",
            title: "The Hobbit",
            subtitle: "Illustrated",
            authors: ["J.R.R. Tolkien"],
            year: "1937",
            audiobook: true,
        )
        let isbn = makeBook(
            uuid: "audio-isbn",
            title: "Hobbit",
            description: "ISBN 978-0-261-10221-7",
            authors: ["Someone Else"],
            audiobook: true,
        )
        let currentWithISBN = makeBook(
            uuid: "ebook",
            title: "The Hobbit!",
            description: "isbn: 9780261102217",
            authors: ["J.R.R. Tolkien"],
            ebook: true,
        )
        let ranked = BookFormatMatcher.candidates(
            for: currentWithISBN,
            in: [currentWithISBN, close, subtitle, otherEdition, isbn],
            links: [],
        )
        #expect(ranked.first?.book.uuid == "audio-isbn")
        #expect(
            Set(ranked.map(\.book.uuid)) == [
                "audio-isbn", "audio-close", "audio-sub", "audio-edition",
            ]
        )
        #expect(ranked.allSatisfy { $0.book.id != currentWithISBN.id })
        let summaries = Dictionary(
            uniqueKeysWithValues: ranked.map { ($0.book.uuid, $0.editionSummary) }
        )
        #expect(summaries["audio-edition"] != summaries["audio-sub"])
        #expect(ranked.first!.score > ranked[1].score)
    }

    @Test func excludesIncompatibleAlreadyLinkedAndPodcasts() {
        let current = makeBook(
            uuid: "ebook",
            title: "Dune",
            authors: ["Frank Herbert"],
            ebook: true
        )
        let sameFormat = makeBook(
            uuid: "other-ebook",
            title: "Dune",
            authors: ["Frank Herbert"],
            ebook: true
        )
        let podcast = makeBook(
            uuid: "pod",
            title: "Dune",
            authors: ["Frank Herbert"],
            audiobook: true,
            tags: ["Podcast"],
        )
        let linkedElsewhere = makeBook(
            uuid: "taken",
            title: "Dune",
            authors: ["Frank Herbert"],
            audiobook: true
        )
        let partner = makeBook(uuid: "partner", title: "Other", audiobook: true)
        let good = makeBook(
            uuid: "good",
            title: "Dune",
            authors: ["Frank Herbert"],
            audiobook: true
        )
        let otherSource = makeBook(
            uuid: "other-source",
            title: "Dune",
            authors: ["Frank Herbert"],
            audiobook: true,
            source: "other",
        )
        let links = [
            BookFormatLink(
                id: "taken",
                members: [partner.id, linkedElsewhere.id],
                primary: partner.id,
                updatedAt: Date(timeIntervalSince1970: 10),
                removed: false,
            )
        ]
        let ranked = BookFormatMatcher.candidates(
            for: current,
            in: [current, sameFormat, podcast, linkedElsewhere, partner, good, otherSource],
            links: links,
        )
        #expect(ranked.map(\.book.uuid) == ["good"])
    }

    @Test func searchStillFindsLowerRankedEditions() {
        let current = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let match = makeBook(
            uuid: "audio",
            title: "Children of Dune",
            authors: ["Frank Herbert"],
            audiobook: true
        )
        let noise = makeBook(uuid: "noise", title: "Unrelated", audiobook: true)
        let ranked = BookFormatMatcher.candidates(
            for: current,
            in: [current, match, noise],
            links: [],
            query: "children",
        )
        #expect(ranked.map(\.book.uuid) == ["audio"])
    }

    @Test func seriesMatchOutranksATitleOnlyEdition() throws {
        let series = try JSONDecoder().decode(
            BookSeries.self,
            from: Data(#"{"name":"Mistborn","featured":0,"position":1}"#.utf8),
        )
        let current = makeBook(
            uuid: "ebook",
            title: "The Final Empire",
            authors: ["Brandon Sanderson"],
            series: [series],
            ebook: true,
        )
        let seriesMatch = makeBook(
            uuid: "series-audio",
            title: "Final Empire",
            authors: ["Brandon Sanderson"],
            series: [series],
            audiobook: true,
        )
        let titleOnly = makeBook(
            uuid: "title-audio",
            title: "The Final Empire",
            authors: ["Someone Else"],
            audiobook: true,
        )
        let ranked = BookFormatMatcher.candidates(
            for: current,
            in: [current, titleOnly, seriesMatch],
            links: [],
        )
        #expect(ranked.map(\.book.uuid) == ["series-audio", "title-audio"])
        #expect(ranked[0].score > ranked[1].score)
        #expect(ranked[0].editionSummary.contains("Mistborn"))
    }

    @Test func groupingHidesOnlyTheLinkedRecord() {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", subtitle: "Full cast", audiobook: true)
        let otherEdition = makeBook(
            uuid: "edition",
            title: "Dune",
            subtitle: "Graphic novel",
            ebook: true
        )
        let link = BookFormatLink(
            id: BookFormatLink.identifier(for: [ebook.id, audio.id]),
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 5),
            removed: false,
        )
        let visible = BookFormatGrouping.visibleBooks([ebook, audio, otherEdition], links: [link])
        #expect(visible.map(\.uuid) == ["ebook", "edition"])
        let actions = BookFormatGrouping.playbackActions(
            for: BookFormatGrouping.members(
                of: ebook.id,
                in: [ebook, audio, otherEdition],
                links: [link]
            )
        )
        #expect(actions.map(\.kind) == [.read, .listen])
        let oneLeft = BookFormatGrouping.visibleBooks([ebook], links: [link])
        #expect(oneLeft.map(\.uuid) == ["ebook"])
    }

    @Test func readAndListenAppearsOnlyWhenStorytellerSaysAligned() {
        let queued = makeBook(
            uuid: "q",
            title: "Dune",
            ebook: true,
            audiobook: true,
            readaloud: "QUEUED"
        )
        let failed = makeBook(
            uuid: "f",
            title: "Dune",
            ebook: true,
            audiobook: true,
            readaloud: "ERROR"
        )
        let ready = makeBook(
            uuid: "r",
            title: "Dune",
            ebook: true,
            audiobook: true,
            readaloud: "ALIGNED"
        )
        #expect(BookFormatGrouping.playbackActions(for: [queued]).map(\.kind) == [.read, .listen])
        #expect(BookFormatGrouping.playbackActions(for: [failed]).map(\.kind) == [.read, .listen])
        #expect(
            BookFormatGrouping.playbackActions(for: [ready]).map(\.kind) == [
                .read, .listen, .readAndListen,
            ]
        )

        #expect(BookFormatAlignment.assess([queued]).phase == .queued)
        #expect(BookFormatAlignment.assess([queued]).canStart == false)
        #expect(BookFormatAlignment.assess([failed]).phase == .failed)
        #expect(BookFormatAlignment.assess([failed]).canRetry == true)
        #expect(BookFormatAlignment.assess([ready]).phase == .ready)
        let split = BookFormatAlignment.assess([
            makeBook(uuid: "e", title: "Dune", ebook: true),
            makeBook(uuid: "a", title: "Dune", audiobook: true),
        ])
        #expect(split.phase == .unavailable)
        #expect(split.canStart == false)
        #expect(split.message.contains("does not create a Readaloud"))
    }

    @Test func freshServerDocumentGroupsWithoutHidingAnotherEdition() async throws {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let edition = makeBook(uuid: "edition", title: "Dune", subtitle: "2021", ebook: true)
        let link = BookFormatLink(
            id: BookFormatLink.identifier(for: [ebook.id, audio.id]),
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 20),
            removed: false,
        )
        let remote = BookFormatLinkDocument(updatedAt: link.updatedAt, links: [link])
        let encoded = try BookFormatLinkMerge.encodeDescription(remote)
        #expect(!encoded.contains("sourceID"))
        let decoded = try BookFormatLinkMerge.decodeDescription(encoded, sourceID: "server")
        #expect(!decoded.needsRewrite)
        let cache = FormatLinkCacheDouble()
        let transport = FormatLinkTransportDouble()
        await transport.setFetch(.document(encoded))
        let coordinator = BookFormatLinkCoordinator(cache: cache, transport: transport)
        let active = await coordinator.refresh(sourceID: "server")
        let stored = await cache.load(sourceID: "server")
        #expect(active.map(\.id) == [link.id])
        #expect(stored.activeLinks.map(\.id) == [link.id])
        #expect(await transport.pushCount == 0)
        let visible = BookFormatGrouping.visibleBooks(
            [ebook, audio, edition],
            links: stored.activeLinks
        )
        #expect(visible.map(\.uuid) == ["ebook", "edition"])
    }

    @Test func successfulLinkPersistsAndDoesNotDeleteBooks() async {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let library = [ebook, audio]
        let cache = FormatLinkCacheDouble()
        let transport = FormatLinkTransportDouble()
        let coordinator = BookFormatLinkCoordinator(cache: cache, transport: transport)
        let outcome = await coordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: library,
            startAlignment: false,
        )
        guard case .linked(let document, let alignment) = outcome else {
            Issue.record("expected linked, got \(outcome)")
            return
        }
        #expect(alignment.phase == .unavailable)
        #expect(document.activeLinks.count == 1)
        #expect(Set(document.activeLinks[0].members) == Set([ebook.id, audio.id]))
        #expect(await cache.load(sourceID: "server") == document)
        #expect(library.map(\.uuid) == ["ebook", "audio"])
        let visible = BookFormatGrouping.visibleBooks(library, links: document.activeLinks)
        #expect(visible.map(\.uuid) == ["ebook"])
    }

    @Test func serverFailureDoesNotSaveALink() async {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let cache = FormatLinkCacheDouble()
        let transport = FormatLinkTransportDouble()
        await transport.setPush(.failure(reason: "server rejected"))
        let coordinator = BookFormatLinkCoordinator(cache: cache, transport: transport)
        let outcome = await coordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook, audio],
            startAlignment: false,
        )
        #expect(outcome == .failed(.serverRejected))
        #expect(await cache.load(sourceID: "server") == .empty)
        #expect(await transport.pushCount == 1)
    }

    @Test func offlineAndExpiredAuthDoNotLink() async {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let cache = FormatLinkCacheDouble()
        let offline = FormatLinkTransportDouble()
        await offline.setFetch(.unavailable(reason: "offline"))
        let offlineCoordinator = BookFormatLinkCoordinator(cache: cache, transport: offline)
        let offlineOutcome = await offlineCoordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook, audio],
            startAlignment: false,
        )
        #expect(offlineOutcome == .failed(.offline))
        #expect(await offline.pushCount == 0)

        let expired = FormatLinkTransportDouble()
        await expired.setFetch(.unavailable(reason: "auth failed"))
        let expiredCoordinator = BookFormatLinkCoordinator(cache: cache, transport: expired)
        let expiredOutcome = await expiredCoordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook, audio],
            startAlignment: false,
        )
        #expect(expiredOutcome == .failed(.authenticationExpired))
        #expect(await cache.load(sourceID: "server") == .empty)
    }

    @Test func missingSourceIsRejectedBeforePush() async {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let transport = FormatLinkTransportDouble()
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport
        )
        let outcome = await coordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook],
            startAlignment: false,
        )
        #expect(outcome == .failed(.sourceMissing))
        #expect(await transport.pushCount == 0)
    }

    @Test func duplicateConfirmationDoesNotPushTwice() async {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let transport = FormatLinkTransportDouble()
        await transport.holdNextPushes()
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport
        )
        async let first = coordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook, audio],
            startAlignment: false,
        )
        while await transport.pushCount == 0 {
            await Task.yield()
        }
        let second = await coordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook, audio],
            startAlignment: false,
        )
        #expect(second == .failed(.duplicateSubmission))
        await transport.releasePushes()
        let firstOutcome = await first
        guard case .linked = firstOutcome else {
            Issue.record("expected the first link to succeed")
            return
        }
        #expect(await transport.pushCount == 1)
    }

    @Test func unlinkKeepsBothBooks() async throws {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let link = BookFormatLink(
            id: BookFormatLink.identifier(for: [ebook.id, audio.id]),
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 1),
            removed: false,
        )
        let cache = FormatLinkCacheDouble()
        await cache.save(
            sourceID: "server",
            document: BookFormatLinkDocument(updatedAt: link.updatedAt, links: [link])
        )
        let transport = FormatLinkTransportDouble()
        await transport.setFetch(
            .document(
                try BookFormatLinkMerge.encodeDescription(
                    BookFormatLinkDocument(updatedAt: link.updatedAt, links: [link])
                )
            )
        )
        let coordinator = BookFormatLinkCoordinator(cache: cache, transport: transport)
        let outcome = await coordinator.unlink(sourceID: "server", bookID: ebook.id)
        guard case .unlinked(let document) = outcome else {
            Issue.record("expected unlinked")
            return
        }
        #expect(document.activeLinks.isEmpty)
        #expect(
            document.links.contains {
                $0.removed && $0.members.contains(ebook.id) && $0.members.contains(audio.id)
            }
        )
        let library = [ebook, audio]
        #expect(BookFormatGrouping.visibleBooks(library, links: document.activeLinks).count == 2)
        #expect(library.count == 2)
    }

    @Test func alignmentStartDoesNotClaimReady() async {
        let host = makeBook(uuid: "host", title: "Dune", ebook: true, audiobook: true)
        let existing = makeBook(uuid: "existing", title: "Dune", readaloud: "ALIGNED")
        let reuseTransport = FormatLinkTransportDouble()
        let reuse = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: reuseTransport
        )
        let reuseOutcome = await reuse.link(
            sourceID: "server",
            primary: host,
            other: existing,
            library: [host, existing],
            startAlignment: true,
        )
        guard case .linked(_, let reused) = reuseOutcome else {
            Issue.record("expected to reuse the ready Readaloud")
            return
        }
        #expect(reused.phase == .ready)
        #expect(await reuseTransport.alignmentStarts.isEmpty)

        let pendingFile = makeBook(uuid: "file", title: "Dune", readaloud: "")
        let failedTransport = FormatLinkTransportDouble()
        await failedTransport.setAlignmentResult(false)
        let failed = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: failedTransport
        )
        let failedOutcome = await failed.link(
            sourceID: "server",
            primary: host,
            other: pendingFile,
            library: [host, pendingFile],
            startAlignment: true,
        )
        guard case .linked(_, let notReady) = failedOutcome else {
            Issue.record("expected the link to succeed without a ready Readaloud")
            return
        }
        #expect(notReady.phase == .failed)
        #expect(notReady.phase != .ready)
        #expect(await failedTransport.alignmentStarts.count == 1)

        let retryTransport = FormatLinkTransportDouble()
        let retry = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: retryTransport
        )
        let retryOutcome = await retry.retryAlignment(members: [
            makeBook(
                uuid: "broken",
                title: "Dune",
                ebook: true,
                audiobook: true,
                readaloud: "ERROR"
            )
        ])
        guard case .alignment(let queued) = retryOutcome else {
            Issue.record("expected queued alignment")
            return
        }
        #expect(queued.phase == .queued)
        #expect(queued.phase != .ready)
        #expect(await retryTransport.alignmentStarts.map(\.1) == [.full])
    }

    @Test func tombstoneFromServerSurvivesRefresh() async throws {
        let ebook = makeBook(uuid: "ebook", title: "Dune", ebook: true)
        let audio = makeBook(uuid: "audio", title: "Dune", audiobook: true)
        let id = BookFormatLink.identifier(for: [ebook.id, audio.id])
        let local = BookFormatLink(
            id: id,
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 1),
            removed: false,
        )
        let remote = BookFormatLink(
            id: id,
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 5),
            removed: true,
        )
        let cache = FormatLinkCacheDouble()
        await cache.save(
            sourceID: "server",
            document: BookFormatLinkDocument(updatedAt: local.updatedAt, links: [local]),
        )
        let transport = FormatLinkTransportDouble()
        await transport.setFetch(
            .document(
                try BookFormatLinkMerge.encodeDescription(
                    BookFormatLinkDocument(updatedAt: remote.updatedAt, links: [remote])
                )
            )
        )
        let coordinator = BookFormatLinkCoordinator(cache: cache, transport: transport)
        let active = await coordinator.refresh(sourceID: "server")
        #expect(active.isEmpty)
        #expect(BookFormatGrouping.visibleBooks([ebook, audio], links: active).count == 2)
    }

    @Test func linkOnOneDeviceGroupsOnAnotherAndUnlinkRoundTrips() async throws {
        let phoneEbook = makeBook(
            uuid: "ebook-uuid",
            title: "Dune",
            ebook: true,
            source: "phone-source"
        )
        let phoneAudio = makeBook(
            uuid: "audio-uuid",
            title: "Dune",
            audiobook: true,
            source: "phone-source"
        )
        let phoneLibrary = [phoneEbook, phoneAudio]
        let phoneTransport = FormatLinkTransportDouble()
        let phone = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: phoneTransport
        )
        let linked = await phone.link(
            sourceID: "phone-source",
            primary: phoneEbook,
            other: phoneAudio,
            library: phoneLibrary,
            startAlignment: false,
        )
        guard case .linked = linked else {
            Issue.record("expected the phone to link the formats")
            return
        }
        let pushed = try #require(await phoneTransport.pushedDescriptions.last)
        #expect(!pushed.contains("phone-source"))
        #expect(!pushed.contains("sourceID"))
        #expect(pushed.contains("ebook-uuid"))
        #expect(pushed.contains("audio-uuid"))

        let ipadEbook = makeBook(
            uuid: "ebook-uuid",
            title: "Dune",
            ebook: true,
            source: "ipad-source"
        )
        let ipadAudio = makeBook(
            uuid: "audio-uuid",
            title: "Dune",
            audiobook: true,
            source: "ipad-source"
        )
        let otherEdition = makeBook(
            uuid: "other-edition",
            title: "Dune",
            subtitle: "Graphic novel",
            ebook: true,
            source: "ipad-source",
        )
        let ipadLibrary = [ipadEbook, ipadAudio, otherEdition]
        let ipadTransport = FormatLinkTransportDouble()
        await ipadTransport.setFetch(.document(pushed))
        let ipad = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: ipadTransport
        )
        let ipadLinks = await ipad.refresh(sourceID: "ipad-source")
        #expect(
            ipadLinks.map(\.id) == [
                BookFormatLink.identifier(forUUIDs: ["ebook-uuid", "audio-uuid"])
            ]
        )
        #expect(ipadLinks.first?.members.allSatisfy { $0.sourceID == "ipad-source" } == true)

        let visible = BookFormatGrouping.visibleBooks(ipadLibrary, links: ipadLinks)
        #expect(visible.map(\.uuid) == ["ebook-uuid", "other-edition"])
        let detail = BookFormatGrouping.members(of: ipadEbook.id, in: ipadLibrary, links: ipadLinks)
        #expect(detail.map(\.uuid) == ["ebook-uuid", "audio-uuid"])
        let actions = BookFormatGrouping.playbackActions(for: detail)
        #expect(actions.map(\.kind) == [.read, .listen])
        #expect(actions.map(\.bookID) == [ipadEbook.id, ipadAudio.id])

        let unlinked = await ipad.unlink(sourceID: "ipad-source", bookID: ipadEbook.id)
        guard case .unlinked = unlinked else {
            Issue.record("expected the iPad to unlink")
            return
        }
        let tombstone = try #require(await ipadTransport.pushedDescriptions.last)
        let stableID = BookFormatLink.identifier(forUUIDs: ["ebook-uuid", "audio-uuid"])
        #expect(tombstone.contains(stableID))
        #expect(!tombstone.contains("ipad-source"))
        #expect(!tombstone.contains("phone-source"))
        #expect(ipadLibrary == [ipadEbook, ipadAudio, otherEdition])

        await phoneTransport.setFetch(.document(tombstone))
        let phoneLinks = await phone.refresh(sourceID: "phone-source")
        #expect(phoneLinks.isEmpty)
        #expect(
            BookFormatGrouping.visibleBooks(phoneLibrary, links: phoneLinks).map(\.uuid) == [
                "ebook-uuid", "audio-uuid",
            ]
        )
        #expect(phoneLibrary == [phoneEbook, phoneAudio])
    }

    @Test func legacyCompositeBookIDsRehydrateOntoTheCurrentSource() async throws {
        let legacy = """
            {"links":[{"id":"phone-source/audio-uuid|phone-source/ebook-uuid","members":[{"sourceID":"phone-source","uuid":"ebook-uuid"},{"sourceID":"phone-source","uuid":"audio-uuid"}],"primary":{"sourceID":"phone-source","uuid":"ebook-uuid"},"removed":false,"updatedAt":"1970-01-01T00:00:05Z"}],"schemaVersion":1,"updatedAt":"1970-01-01T00:00:05Z"}
            """
        let decoded = try BookFormatLinkMerge.decodeDescription(legacy, sourceID: "ipad-source")
        #expect(decoded.needsRewrite)
        let link = try #require(decoded.document.activeLinks.first)
        #expect(link.primary == BookID(sourceID: "ipad-source", uuid: "ebook-uuid"))
        #expect(link.removed == false)
        #expect(link.id == "audio-uuid|ebook-uuid")
        #expect(link.updatedAt == Date(timeIntervalSince1970: 5))

        let transport = FormatLinkTransportDouble()
        await transport.setFetch(.document(legacy))
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport
        )
        let active = await coordinator.refresh(sourceID: "ipad-source")
        #expect(active.first?.members.allSatisfy { $0.sourceID == "ipad-source" } == true)
        let pushed = try #require(await transport.pushedDescriptions.first)
        #expect(!pushed.contains("phone-source"))
        #expect(!pushed.contains("sourceID"))
        #expect(pushed.contains("\"schemaVersion\":2"))
        #expect(pushed.contains("ebook-uuid"))
    }

    @Test func linksDoNotCrossStorytellerSourcesWithTheSameBookUUID() {
        let phoneEbook = makeBook(
            uuid: "ebook-uuid",
            title: "Dune",
            ebook: true,
            source: "phone-source"
        )
        let phoneAudio = makeBook(
            uuid: "audio-uuid",
            title: "Dune",
            audiobook: true,
            source: "phone-source"
        )
        let padEbook = makeBook(
            uuid: "ebook-uuid",
            title: "Dune",
            ebook: true,
            source: "ipad-source"
        )
        let padAudio = makeBook(
            uuid: "audio-uuid",
            title: "Dune",
            audiobook: true,
            source: "ipad-source"
        )
        let link = BookFormatLink(
            members: [phoneEbook.id, phoneAudio.id],
            primary: phoneEbook.id,
            updatedAt: Date(timeIntervalSince1970: 1),
            removed: false,
        )
        let visible = BookFormatGrouping.visibleBooks(
            [phoneEbook, phoneAudio, padEbook, padAudio],
            links: [link],
        )
        #expect(visible.map(\.id) == [phoneEbook.id, padEbook.id, padAudio.id])
        let padMembers = BookFormatGrouping.members(
            of: padEbook.id,
            in: [phoneEbook, phoneAudio, padEbook, padAudio],
            links: [link],
        )
        #expect(padMembers.map(\.id) == [padEbook.id])
    }
}

private func makeBook(
    uuid: String,
    title: String,
    subtitle: String? = nil,
    description: String? = nil,
    authors: [String] = [],
    year: String? = nil,
    series: [BookSeries]? = nil,
    ebook: Bool = false,
    audiobook: Bool = false,
    readaloud: String? = nil,
    tags: [String] = [],
    source: BookSourceID = "server",
) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: source, uuid: uuid),
        title: title,
        subtitle: subtitle,
        description: description,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: year.map { "\($0)-01-01" },
        authors: authors.map {
            BookCreator(
                uuid: nil,
                id: nil,
                name: $0,
                fileAs: nil,
                role: "aut",
                createdAt: nil,
                updatedAt: nil
            )
        },
        narrators: nil,
        creators: nil,
        series: series,
        tags: tags.map { BookTag(uuid: nil, name: $0, createdAt: nil, updatedAt: nil) },
        collections: nil,
        ebook: ebook
            ? BookAsset(
                uuid: uuid,
                filepath: "\(uuid).epub",
                missing: 0,
                createdAt: nil,
                updatedAt: nil
            ) : nil,
        audiobook: audiobook
            ? BookAsset(
                uuid: uuid,
                filepath: "\(uuid).m4b",
                missing: 0,
                createdAt: nil,
                updatedAt: nil
            ) : nil,
        readaloud: readaloud == nil
            ? nil
            : BookReadaloud(
                uuid: uuid,
                filepath: "\(uuid)-read.epub",
                missing: 0,
                status: readaloud,
                currentStage: nil,
                stageProgress: nil,
                queuePosition: nil,
                restartPending: nil,
                createdAt: nil,
                updatedAt: nil,
            ),
        status: nil,
        position: nil,
        rating: nil,
    )
}

actor FormatLinkCacheDouble: BookFormatLinkCache {
    var documents: [BookSourceID: BookFormatLinkDocument] = [:]

    func load(sourceID: BookSourceID) async -> BookFormatLinkDocument {
        documents[sourceID] ?? .empty
    }

    func save(sourceID: BookSourceID, document: BookFormatLinkDocument) async {
        documents[sourceID] = document
    }
}

final class FormatLinkPushGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func openGate() {
        lock.lock()
        open = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }
}

actor FormatLinkTransportDouble: BookFormatLinkTransport {
    var fetchResult: BookFormatLinkFetchResult = .empty
    var pushResult: BookFormatLinkPushResult = .success
    private(set) var pushCount = 0
    private(set) var pushedDescriptions: [String] = []
    private(set) var alignmentStarts: [(BookID, AlignmentRestartMode)] = []
    private var alignmentResult = true
    private var holdPush = false
    private let gate = FormatLinkPushGate()
    var canMerge = true
    var mergeResult: StorytellerBookMergeHTTPResult = .failure(.serverRejected)
    private(set) var mergeCount = 0
    private(set) var mergeRequests: [StorytellerBookMergeRequest] = []
    private var holdMerge = false
    private let mergeGate = FormatLinkPushGate()

    func setFetch(_ result: BookFormatLinkFetchResult) {
        fetchResult = result
    }

    func setPush(_ result: BookFormatLinkPushResult) {
        pushResult = result
    }

    func setAlignmentResult(_ result: Bool) {
        alignmentResult = result
    }

    func holdNextPushes() {
        holdPush = true
    }

    func releasePushes() {
        gate.openGate()
    }

    func setMerge(_ result: StorytellerBookMergeHTTPResult) {
        mergeResult = result
    }

    func setCanMerge(_ value: Bool) {
        canMerge = value
    }

    func holdNextMerges() {
        holdMerge = true
    }

    func releaseMerges() {
        mergeGate.openGate()
    }

    func fetchDocument(sourceID: BookSourceID) async -> BookFormatLinkFetchResult {
        _ = sourceID
        return fetchResult
    }

    func pushDocument(
        sourceID: BookSourceID,
        description: String,
    ) async -> BookFormatLinkPushResult {
        _ = sourceID
        pushCount += 1
        pushedDescriptions.append(description)
        if holdPush {
            await gate.wait()
        }
        return pushResult
    }

    func startAlignment(bookID: BookID, restart: AlignmentRestartMode) async -> Bool {
        alignmentStarts.append((bookID, restart))
        return alignmentResult
    }

    func canMergeBooks(sourceID: BookSourceID) async -> Bool {
        _ = sourceID
        return canMerge
    }

    func mergeBooks(
        sourceID: BookSourceID,
        request: StorytellerBookMergeRequest,
    ) async -> StorytellerBookMergeHTTPResult {
        _ = sourceID
        mergeCount += 1
        mergeRequests.append(request)
        if holdMerge {
            await mergeGate.wait()
        }
        return mergeResult
    }
}
