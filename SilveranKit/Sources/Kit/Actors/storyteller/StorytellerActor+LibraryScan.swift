import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension StorytellerActor {
    /// Triggers Storyteller’s server-side library scan (`POST /api/v2/books/scan`).
    ///
    /// Matches web Settings “Scan library”: optional `force=true` (default true).
    /// A 204 means the scan was **accepted** and runs in the background — not that it finished.
    public func scanLibrary(force: Bool = StorytellerLibraryScan.defaultForce) async
        -> Result<Void, StorytellerLibraryScan.Failure>
    {
        guard isConfigured else { return .failure(.notConfigured) }
        guard let (baseURL, token) = await ensureAuthentication() else {
            return .failure(Self.scanAuthFailure(for: connectionStatus))
        }

        let scanURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(StorytellerLibraryScan.pathComponent)

        var query: [String: String] = [:]
        if force {
            query["force"] = "true"
        }

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)
        allowedStatuses.insert(405)

        debugLog(
            "[StorytellerActor] scanLibrary request started endpoint=POST books/scan force=\(force)"
        )

        do {
            let response = try await httpPost(
                scanURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                queryParameters: query,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            debugLog(
                "[StorytellerActor] scanLibrary HTTP \(response.statusCode) endpoint=books/scan"
            )

            // 403 here is missing `bookProcess`, not an expired session — avoid clearing the token.
            if response.statusCode == 403 {
                return .failure(.permissionDenied)
            }

            switch evaluateResponse(
                response,
                methodName: "scanLibrary",
                context: "library scan",
            ) {
                case .success:
                    debugLog(
                        "[StorytellerActor] scanLibrary accepted (server-side scan started/queued)"
                    )
                    return .success(())
                case .unauthorized:
                    return .failure(.authenticationFailed)
                case .notFound:
                    return .failure(.unsupported)
                case .notModified:
                    return .failure(.rejected(statusCode: 304))
                case .unexpected(let code):
                    return .failure(.rejected(statusCode: code))
            }
        } catch {
            logStorytellerError("scanLibrary", error: error)
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// Reads scan progress (`GET /api/v2/books/scan`).
    public func fetchScanState() async -> Result<
        StorytellerLibraryScan.State, StorytellerLibraryScan.Failure
    > {
        guard isConfigured else { return .failure(.notConfigured) }
        guard let (baseURL, token) = await ensureAuthentication() else {
            return .failure(Self.scanAuthFailure(for: connectionStatus))
        }

        let scanURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(StorytellerLibraryScan.pathComponent)

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)

        do {
            let response = try await httpGet(
                scanURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            debugLog(
                "[StorytellerActor] fetchScanState HTTP \(response.statusCode) endpoint=books/scan"
            )

            if response.statusCode == 403 {
                return .failure(.permissionDenied)
            }

            switch evaluateResponse(
                response,
                methodName: "fetchScanState",
                context: "library scan state",
            ) {
                case .success:
                    do {
                        let state = try StorytellerLibraryScan.parseState(from: response.data)
                        debugLog(
                            "[StorytellerActor] fetchScanState running=\(state.running) source=\(state.source ?? "nil")"
                        )
                        return .success(state)
                    } catch {
                        logStorytellerError("fetchScanState decode", error: error)
                        return .failure(.transport("Unexpected scan status response"))
                    }
                case .unauthorized:
                    return .failure(.authenticationFailed)
                case .notFound:
                    return .failure(.unsupported)
                case .notModified:
                    return .failure(.rejected(statusCode: 304))
                case .unexpected(let code):
                    return .failure(.rejected(statusCode: code))
            }
        } catch {
            logStorytellerError("fetchScanState", error: error)
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// POST scan, optionally poll GET until finished or budget exhausted, then report outcome.
    public func scanLibraryAndAwaitStatus(
        force: Bool = StorytellerLibraryScan.defaultForce,
        polling: StorytellerLibraryScan.Polling = .default,
    ) async -> StorytellerLibraryScan.Outcome {
        switch await scanLibrary(force: force) {
            case .failure(let failure):
                return .failure(failure)
            case .success:
                break
        }

        if Task.isCancelled {
            return .failure(.cancelled)
        }

        var observed: [StorytellerLibraryScan.State] = []
        for attempt in 0..<polling.maxAttempts {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: polling.intervalNanoseconds)
            }
            if Task.isCancelled {
                return .failure(.cancelled)
            }

            switch await fetchScanState() {
                case .failure(let failure):
                    // Status probe failed after accept — still an accepted start.
                    debugLog(
                        "[StorytellerActor] scanLibraryAndAwaitStatus status probe failed: \(failure)"
                    )
                    let completion = StorytellerLibraryScan.completion(
                        afterStates: observed,
                        exhaustedBudget: true,
                    )
                    return .success(completion)
                case .success(let state):
                    observed.append(state)
                    if observed.contains(where: \.running) && !state.running {
                        return .success(.confirmedComplete)
                    }
            }
        }

        let completion = StorytellerLibraryScan.completion(
            afterStates: observed,
            exhaustedBudget: true,
        )
        debugLog(
            "[StorytellerActor] scanLibraryAndAwaitStatus finished polling completion=\(completion)"
        )
        return .success(completion)
    }

    private static func scanAuthFailure(for status: ConnectionStatus)
        -> StorytellerLibraryScan.Failure
    {
        switch status {
            case .disconnected:
                return .notConnected
            case .error:
                return .authenticationFailed
            case .connecting, .connected:
                return .authenticationFailed
        }
    }
}
