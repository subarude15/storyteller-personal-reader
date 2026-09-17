//
//  PodcastBrowseChartsService.swift
//  ink+amp
//
//  Loads Top Charts / genre charts via free Apple iTunes RSS + lookup.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit

/// Fetches Apple podcast charts for Find → Browse (no API keys).
public struct PodcastBrowseChartsService: Sendable {
    public static let shared = PodcastBrowseChartsService()

    private init() {}

    public func chart(
        genre: PodcastBrowseGenre,
        limit: Int = 25,
        storefront: String? = nil
    ) async throws -> [PodcastChartHit] {
        let cc = (storefront ?? Locale.current.region?.identifier ?? "us").lowercased()
        let chartURL = PodcastAppleCharts.chartURL(
            storefront: cc,
            limit: limit,
            genreID: genre.genreID
        )

        var request = URLRequest(url: chartURL)
        request.setValue("ink-amp/1.0 (Podcast Browse)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let chartData: Data
        let chartResponse: URLResponse
        do {
            (chartData, chartResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw PodcastAppleChartsError.offline
        }
        guard let http = chartResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            throw PodcastAppleChartsError.badResponse
        }

        let stubs = try PodcastAppleCharts.parseClassicChart(chartData)
        guard let lookupURL = PodcastAppleCharts.lookupURL(
            collectionIDs: stubs.map(\.collectionID)
        )
        else {
            throw PodcastAppleChartsError.empty
        }

        var lookupRequest = URLRequest(url: lookupURL)
        lookupRequest.setValue("ink-amp/1.0 (Podcast Browse)", forHTTPHeaderField: "User-Agent")
        lookupRequest.timeoutInterval = 20

        let lookupData: Data
        let lookupResponse: URLResponse
        do {
            (lookupData, lookupResponse) = try await URLSession.shared.data(for: lookupRequest)
        } catch {
            throw PodcastAppleChartsError.offline
        }
        guard let lookupHTTP = lookupResponse as? HTTPURLResponse,
            (200..<300).contains(lookupHTTP.statusCode)
        else {
            throw PodcastAppleChartsError.badResponse
        }

        return try PodcastAppleCharts.mergeLookup(stubs: stubs, lookupData: lookupData)
    }
}
