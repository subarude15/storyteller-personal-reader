//
//  ManualAcquisitionHandoffTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual Search handoff boundary")
struct ManualAcquisitionHandoffTests {
    private let book = ManualSearchBookContext(title: "The Hobbit", authors: ["J.R.R. Tolkien"])

    @Test func detectedCandidateReachesPlaceholderHandler() async throws {
        let url = try #require(URL(string: "https://files.example.com/hobbit.epub"))
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(
                url: url,
                mimeType: "application/epub+zip",
                suggestedFilename: "hobbit.epub",
                bookMetadata: book,
                providerID: "open-library",
            )
        )
        let handler = RecordingManualAcquisitionHandler()
        let router = ManualAcquisitionRouter(handler: handler)
        let result = await router.submit(candidate)
        #expect(handler.received.count == 1)
        #expect(handler.received[0].sourceURL == url)
        #expect(handler.received[0].detectedType == .epub)
        #expect(handler.received[0].bookMetadata.title == "The Hobbit")
        #expect(result == .placeholder(message: PlaceholderManualAcquisitionHandler.message))
        #expect(result.message == "NAS handoff will be added in the next update.")
    }

    @Test func placeholderDoesNotPretendTheNASSucceeded() async {
        let handler = PlaceholderManualAcquisitionHandler()
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
            detectedType: .magnet,
            bookMetadata: book,
        )
        let result = await handler.handle(candidate)
        #expect(result == .placeholder(message: PlaceholderManualAcquisitionHandler.message))
        switch result {
            case .placeholder(let message):
                #expect(message.contains("next update"))
                #expect(!message.lowercased().contains("sent"))
                #expect(!message.lowercased().contains("queued"))
                #expect(!message.lowercased().contains("downloaded"))
            case .submitted, .completed, .failed:
                Issue.record("placeholder handler must not submit or fail")
        }
    }

    @Test func routerDoesNotReferenceNASClients() {
        let routerType = String(describing: ManualAcquisitionRouter.self)
        let handlerType = String(describing: PlaceholderManualAcquisitionHandler.self)
        for name in ["qBittorrent", "Deluge", "Synology", "QBittorrent"] {
            #expect(!routerType.contains(name))
            #expect(!handlerType.contains(name))
        }
    }
}
