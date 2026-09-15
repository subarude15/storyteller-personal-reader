//
//  PunkRallyStatsModels.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Models/Statistics/{ListeningStatsModels,ReadingStatsModels,HistorySessionModels}.swift
//  Modifications: local-only aggregates; no provider or server sync fields.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One recorded media session (a reading or listening block).
public struct PRMediaSession: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case reading
        case listening
    }

    public var id: UUID
    public var kind: Kind
    public var mediaID: String
    public var mediaTitle: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: TimeInterval
    /// Where the session left off, 0...1
    public var endProgress: Double?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        mediaID: String,
        mediaTitle: String,
        startedAt: Date,
        endedAt: Date = Date(),
        durationSeconds: TimeInterval = 0,
        endProgress: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mediaID = mediaID
        self.mediaTitle = mediaTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.endProgress = endProgress
    }
}

public struct PRDailyAggregate: Identifiable, Codable, Equatable, Sendable {
    public var id: Date { day }
    public var day: Date
    public var listenSeconds: TimeInterval
    public var readSeconds: TimeInterval

    public init(day: Date, listenSeconds: TimeInterval, readSeconds: TimeInterval) {
        self.day = day
        self.listenSeconds = listenSeconds
        self.readSeconds = readSeconds
    }

    public var totalSeconds: TimeInterval {
        listenSeconds + readSeconds
    }
}

public struct PRStatsSnapshot: Equatable, Sendable {
    public var todaySeconds: TimeInterval
    public var weekSeconds: TimeInterval
    public var streakDays: Int
    public var finishedBooks30d: Int
    public var averageSessionSeconds: TimeInterval
    public var recentDays: [PRDailyAggregate]

    public static let empty = PRStatsSnapshot(
        todaySeconds: 0,
        weekSeconds: 0,
        streakDays: 0,
        finishedBooks30d: 0,
        averageSessionSeconds: 0,
        recentDays: []
    )
}

/// A completion record — when a book reached 100% locally.
public struct PRFinishedBook: Identifiable, Codable, Equatable, Sendable {
    public var id: String { mediaID }
    public var mediaID: String
    public var mediaTitle: String
    public var finishedAt: Date

    public init(mediaID: String, mediaTitle: String, finishedAt: Date) {
        self.mediaID = mediaID
        self.mediaTitle = mediaTitle
        self.finishedAt = finishedAt
    }
}