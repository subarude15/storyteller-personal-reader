//
//  NASFileUploading.swift
//  SilveranKit
//
//  Transport-neutral upload. The handler does not know if this is DSM
//  File Station or another Synology-compatible method.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct NASUploadDestination: Equatable, Sendable {
    public var volumePath: String
    public var filename: String

    public init(volumePath: String, filename: String) {
        self.volumePath = volumePath
        self.filename = filename
    }
}

public struct NASUploadResult: Equatable, Sendable {
    public var remotePath: String
    public var byteCount: Int64?
    public var verified: Bool

    public init(remotePath: String, byteCount: Int64? = nil, verified: Bool) {
        self.remotePath = remotePath
        self.byteCount = byteCount
        self.verified = verified
    }
}

public protocol NASFileUploading: Sendable {
    func upload(localFile: URL, destination: NASUploadDestination) async throws -> NASUploadResult
}

public struct SynologyNASFileUploader: NASFileUploading {
    public var client: SynologyFileStationClient
    public var baseURL: String
    public var username: String
    public var password: String

    public init(
        client: SynologyFileStationClient = SynologyFileStationClient(),
        baseURL: String,
        username: String,
        password: String,
    ) {
        self.client = client
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    public func upload(localFile: URL, destination: NASUploadDestination) async throws -> NASUploadResult {
        try await client.upload(
            baseURL: baseURL,
            username: username,
            password: password,
            localFile: localFile,
            destination: destination,
        )
    }
}
